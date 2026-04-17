defmodule Mix.Tasks.Reach.Smell do
  @moduledoc """
  Finds cross-function performance anti-patterns using data flow analysis.

  Detects redundant traversals, duplicate computations, unused results,
  and suboptimal Enum operations — including patterns that span function
  boundaries.

      mix reach.smell
      mix reach.smell --format json
      mix reach.smell lib/my_app/

  ## Options

    * `--format` — output format: `text` (default), `json`, `oneline`

  """

  use Mix.Task

  @shortdoc "Find cross-function performance anti-patterns"

  @switches [format: :string]
  @aliases [f: :format]

  @impl Mix.Task
  def run(args) do
    {opts, _args, _} = OptionParser.parse(args, switches: @switches, aliases: @aliases)
    format = opts[:format] || "text"

    project = Reach.CLI.Project.load()

    findings =
      detect_pipeline_waste(project) ++
        detect_redundant_computation(project) ++
        detect_unused_results(project) ++
        detect_eager_patterns(project)

    case format do
      "json" ->
        Reach.CLI.Format.render(%{findings: findings}, "reach.smell", format: "json", pretty: true)

      "oneline" ->
        Enum.each(findings, fn f ->
          IO.puts("#{f.location}: #{f.kind}: #{f.message}")
        end)

      _ ->
        render_text(findings)
    end
  end

  # --- Pipeline waste: reverse→reverse, filter→filter, map→count ---

  defp detect_pipeline_waste(project) do
    nodes = Map.values(project.nodes)

    # Find sequences of Enum calls within the same function
    func_defs = Enum.filter(nodes, &(&1.type == :function_def))

    Enum.flat_map(func_defs, fn func ->
      calls =
        func
        |> Reach.IR.all_nodes()
        |> Enum.filter(fn n ->
          n.type == :call and n.meta[:module] in [Enum, Stream] and
            n.meta[:kind] != :fun_ref and
            n.meta[:function] != nil
        end)
        |> Enum.filter(& &1.source_span)
        |> Enum.sort_by(fn n -> {n.source_span[:start_line], n.source_span[:start_col] || 0} end)

      find_pipeline_patterns(calls, project.graph)
    end)
  end

  defp find_pipeline_patterns(calls, graph) do
    calls
    |> Enum.chunk_every(2, 1, [])
    |> Enum.flat_map(fn
      [first, second] ->
        check_pair(first, second, graph)

      _ ->
        []
    end)
  end

  defp check_pair(first, second, graph) do
    connected = data_connected?(first, second, graph)

    cond do
      connected && reverse_pair?(first, second) ->
        [%{
          kind: :redundant_traversal,
          message: "Enum.reverse → Enum.reverse is a no-op",
          location: Reach.CLI.Format.location(second)
        }]

      connected && filter_count?(first, second) ->
        [%{
          kind: :suboptimal,
          message: "Enum.filter → Enum.count: use Enum.count/2 instead",
          location: Reach.CLI.Format.location(second)
        }]

      connected && map_count?(first, second) ->
        [%{
          kind: :suboptimal,
          message: "Enum.map → Enum.count: use Enum.count/2 with transform",
          location: Reach.CLI.Format.location(second)
        }]

      connected && map_map?(first, second) ->
        [%{
          kind: :suboptimal,
          message: "Enum.map → Enum.map: consider fusing into one pass",
          location: Reach.CLI.Format.location(second)
        }]

      connected && filter_filter?(first, second) ->
        [%{
          kind: :suboptimal,
          message: "Enum.filter → Enum.filter: combine predicates into one pass",
          location: Reach.CLI.Format.location(second)
        }]

      true ->
        []
    end
  end

  defp data_connected?(first, second, graph) do
    # Check if second depends on first via data flow
    Graph.has_vertex?(graph, first.id) and Graph.has_vertex?(graph, second.id) and
      first.id in Graph.reaching(graph, [second.id])
  rescue
    _ -> false
  end

  defp reverse_pair?(a, b) do
    a.meta[:function] == :reverse and b.meta[:function] == :reverse and
      a.meta[:arity] == 1 and b.meta[:arity] == 1
  end

  defp filter_count?(a, b) do
    a.meta[:function] == :filter and b.meta[:function] == :count
  end

  defp map_count?(a, b) do
    a.meta[:function] == :map and b.meta[:function] == :count
  end

  defp map_map?(a, b) do
    a.meta[:function] == :map and b.meta[:function] == :map
  end

  defp filter_filter?(a, b) do
    a.meta[:function] == :filter and b.meta[:function] == :filter
  end

  # --- Redundant computation: same pure call twice with same args ---

  defp detect_redundant_computation(project) do
    nodes = Map.values(project.nodes)

    func_defs = Enum.filter(nodes, &(&1.type == :function_def))

    Enum.flat_map(func_defs, fn func ->
      calls =
        func
        |> Reach.IR.all_nodes()
        |> Enum.filter(fn n ->
          n.type == :call and
            Reach.Effects.pure?(n) and
            n.meta[:function] != nil and
            n.source_span != nil
        end)

      # Group by {module, function, arity} and find duplicates
      calls
      |> Enum.group_by(fn n ->
        {n.meta[:module], n.meta[:function], n.meta[:arity]}
      end)
      |> Enum.flat_map(fn {_key, group} ->
        if length(group) > 1 do
          # Check if any pair shares the same args (same variable names)
          find_same_arg_calls(group)
        else
          []
        end
      end)
    end)
    |> Enum.take(20)
  end

  defp find_same_arg_calls(calls) do
    calls
    |> Enum.chunk_every(2, 1, [])
    |> Enum.flat_map(fn
      [a, b] ->
        if same_args?(a, b) and a.source_span[:start_line] != b.source_span[:start_line] do
          [%{
            kind: :redundant_computation,
            message: "#{call_name(a)} called twice with same args (line #{a.source_span[:start_line]} and #{b.source_span[:start_line]})",
            location: Reach.CLI.Format.location(b)
          }]
        else
          []
        end

      _ ->
        []
    end)
  end

  defp same_args?(a, b) do
    a_children = Enum.filter(a.children, &(&1.type == :var))
    b_children = Enum.filter(b.children, &(&1.type == :var))

    length(a_children) == length(b_children) and
      Enum.zip(a_children, b_children)
      |> Enum.all?(fn {ac, bc} ->
        ac.meta[:name] == bc.meta[:name]
      end)
  end

  defp call_name(node) do
    mod = node.meta[:module]
    fun = node.meta[:function]
    if mod, do: "#{inspect(mod)}.#{fun}", else: to_string(fun)
  end

  # --- Unused results: pure call whose return value is discarded ---

  defp detect_unused_results(project) do
    nodes = Map.values(project.nodes)
    graph = project.graph

    nodes
    |> Enum.filter(fn n ->
      n.type == :call and
        Reach.Effects.classify(n) == :pure and
        n.meta[:function] != nil and
        n.source_span != nil and
        not trivial_call?(n)
    end)
    |> Enum.filter(fn n ->
      # Check if the call's result has any data dependents
      Graph.has_vertex?(graph, n.id) and
        Graph.out_degree(graph, n.id) == 0
    end)
    |> Enum.reject(fn n ->
      # Exclude calls that are the last expression in a clause (they ARE the return value)
      is_return_value?(n, nodes)
    end)
    |> Enum.take(20)
    |> Enum.map(fn n ->
      %{
        kind: :unused_result,
        message: "#{call_name(n)} result is unused",
        location: Reach.CLI.Format.location(n)
      }
    end)
  end

  defp trivial_call?(node) do
    node.meta[:function] in [:@, :__aliases__, :__MODULE__, :to_string, :inspect] or
      (is_atom(node.meta[:module]) and to_string(node.meta[:module]) =~ "Reach.CLI")
  end

  defp is_return_value?(node, all_nodes) do
    # Check if this call is the last child of a clause (return value)
    all_nodes
    |> Enum.filter(&(&1.type == :clause))
    |> Enum.any?(fn clause ->
      List.last(clause.children) == node or
        (clause.children |> List.last() |> children_contain?(node))
    end)
  end

  defp children_contain?(parent, target) do
    parent != nil and
      Enum.any?(parent.children || [], fn child ->
        child.id == target.id or children_contain?(child, target)
      end)
  end

  # --- Eager patterns: Enum.map |> List.first, Enum.sort |> Enum.take ---

  defp detect_eager_patterns(project) do
    nodes = Map.values(project.nodes)

    func_defs = Enum.filter(nodes, &(&1.type == :function_def))

    Enum.flat_map(func_defs, fn func ->
      calls =
        func
        |> Reach.IR.all_nodes()
        |> Enum.filter(fn n ->
          n.type == :call and n.meta[:module] in [Enum, List] and
            n.source_span != nil
        end)
        |> Enum.sort_by(fn n -> n.source_span[:start_line] end)

      calls
      |> Enum.chunk_every(2, 1, [])
      |> Enum.flat_map(fn
        [first, second] ->
          cond do
            first.meta[:function] == :map and second.meta[:function] == :first ->
              [%{
                kind: :eager_pattern,
                message: "Enum.map → List.first: builds entire list for one element. Use Enum.find_value/2",
                location: Reach.CLI.Format.location(second)
              }]

            first.meta[:function] == :sort and second.meta[:function] == :take ->
              [%{
                kind: :eager_pattern,
                message: "Enum.sort → Enum.take(#{take_count(second)}): sorts entire list. Consider partial sort",
                location: Reach.CLI.Format.location(second)
              }]

            true ->
              []
          end

        _ ->
          []
      end)
    end)
  end

  defp take_count(node) do
    case node.children do
      [_, %{type: :literal, meta: %{value: n}}] -> n
      _ -> "?"
    end
  end

  # --- Rendering ---

  defp render_text(findings) do
    IO.puts(Reach.CLI.Format.header("Cross-Function Smell Detection"))

    if findings == [] do
      IO.puts("No issues found.\n")
    else
      grouped = Enum.group_by(findings, & &1.kind)

      render_group(Map.get(grouped, :redundant_traversal, []), "Redundant traversals")
      render_group(Map.get(grouped, :suboptimal, []), "Suboptimal patterns")
      render_group(Map.get(grouped, :redundant_computation, []), "Redundant computations")
      render_group(Map.get(grouped, :unused_result, []), "Unused computation results")
      render_group(Map.get(grouped, :eager_pattern, []), "Eager where lazy suffices")

      IO.puts("#{length(findings)} finding(s)\n")
    end
  end

  defp render_group([], _title), do: nil

  defp render_group(findings, title) do
    IO.puts(Reach.CLI.Format.section(title))
    Enum.each(findings, fn f ->
      IO.puts("  #{f.location}")
      IO.puts("    #{f.message}")
    end)
  end
end
