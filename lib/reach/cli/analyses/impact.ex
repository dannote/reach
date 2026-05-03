defmodule Reach.CLI.Analyses.Impact do
  @moduledoc """
  Shows what breaks if a function's signature or return value changes.

      mix reach.inspect UserService.register/2 --impact
      mix reach.inspect lib/my_app/user_service.ex:10 --impact
      mix reach.inspect UserService.register/2 --impact --format json

  ## Options

    * `--format` — output format: `text` (default), `json`, `oneline`
    * `--depth` — transitive caller depth (default: 4)

  """

  @switches [format: :string, depth: :integer, graph: :boolean]
  @aliases [f: :format]

  alias Reach.CLI.BoxartGraph
  alias Reach.CLI.Format
  alias Reach.CLI.Options
  alias Reach.CLI.Project
  alias Reach.IR

  @default_return_dependent_limit 20
  @default_dependency_node_limit 20

  def run(args, cli_opts \\ []) do
    {opts, target_args} = Options.parse(args, @switches, @aliases)

    raw_target =
      List.first(target_args) ||
        Mix.raise(
          "Expected a target. Usage:\n" <>
            "  mix reach.inspect Module.function/arity --impact\n" <>
            "  mix reach.inspect lib/foo.ex:42 --impact"
        )

    run_target(raw_target, opts, cli_opts)
  end

  def run_target(raw_target, opts, cli_opts \\ []) do
    project = Project.load(quiet: opts[:format] == "json")
    target = Project.resolve_target(project, raw_target)

    unless target do
      Mix.raise("Function not found: #{raw_target}")
    end

    depth = opts[:depth] || 4
    result = analyze(project, target, depth)
    render_result(project, target, depth, result, opts, cli_opts)
  end

  defp render_result(project, target, depth, result, opts, cli_opts) do
    cond do
      opts[:graph] ->
        BoxartGraph.require!()
        BoxartGraph.render_caller_graph(project, target, depth)

      opts[:format] == "json" ->
        Format.render(result, command(cli_opts), format: "json", pretty: true)

      opts[:format] == "oneline" ->
        render_oneline(result)

      true ->
        render_text(project, result)
    end
  end

  defp command(cli_opts), do: Keyword.get(cli_opts, :command, "reach.inspect")

  defp analyze(project, target, depth) do
    direct = find_callers(project, target, 1)
    transitive = find_callers(project, target, depth)
    indirect = Enum.reject(transitive, &(&1.id in Enum.map(direct, fn d -> d.id end)))

    return_deps = find_return_dependents(project, target)
    shared = find_shared_data(project, target)

    %{
      target: target,
      direct_callers: direct,
      transitive_callers: indirect,
      return_dependents: return_deps,
      shared_data: shared
    }
  end

  defp find_callers(project, target, depth) do
    cg = project.call_graph

    if Graph.has_vertex?(cg, target) do
      do_find_callers(cg, [target], depth, MapSet.new([target]), [])
    else
      []
    end
  end

  defp do_find_callers(_cg, [], _depth, _visited, acc), do: Enum.reverse(acc)

  defp do_find_callers(_cg, _frontier, 0, _visited, acc), do: Enum.reverse(acc)

  defp do_find_callers(cg, frontier, depth, visited, acc) do
    {new_callers, new_visited} =
      Enum.reduce(frontier, {[], visited}, fn f, {found, vis} ->
        callers =
          Graph.in_neighbors(cg, f)
          |> Enum.filter(&match?({_, _, _}, &1))
          |> Enum.reject(&MapSet.member?(vis, &1))

        {Enum.reverse(callers, found), Enum.reduce(callers, vis, &MapSet.put(&2, &1))}
      end)

    acc = Enum.reduce(new_callers, acc, fn caller, acc -> [%{id: caller} | acc] end)

    if depth > 1 do
      do_find_callers(cg, new_callers, depth - 1, new_visited, acc)
    else
      Enum.reverse(acc)
    end
  end

  defp find_return_dependents(project, target) do
    graph = project.graph
    nodes = project.nodes
    target_key = tuple_with_nil(target)
    callers = find_callers(project, target, 1)

    Enum.flat_map(callers, fn %{id: caller_id} ->
      caller_node = Project.find_function(project, caller_id)
      if caller_node, do: return_deps_for_caller(caller_node, target_key, graph, nodes), else: []
    end)
    |> Enum.uniq_by(& &1.location)
    |> Enum.take(@default_return_dependent_limit)
  end

  defp return_deps_for_caller(caller_node, target_key, graph, nodes) do
    caller_id = {caller_node.meta[:module], caller_node.meta[:name], caller_node.meta[:arity]}

    call_sites =
      caller_node
      |> IR.all_nodes()
      |> Enum.filter(fn n ->
        n.type == :call and
          {n.meta[:module], n.meta[:function], n.meta[:arity] || 0} == target_key
      end)

    Enum.flat_map(call_sites, fn call_site ->
      deps_from_call_site(call_site, caller_id, graph, nodes)
    end)
  end

  defp deps_from_call_site(call_site, caller_id, graph, nodes) do
    if Graph.has_vertex?(graph, call_site.id) do
      graph
      |> Graph.reachable([call_site.id])
      |> Enum.take(@default_dependency_node_limit)
      |> Enum.map(&Map.get(nodes, &1))
      |> Enum.reject(&is_nil/1)
      |> Enum.map(fn dep_node ->
        %{
          in_function: caller_id,
          node_type: dep_node.type,
          location: Format.location(dep_node)
        }
      end)
    else
      []
    end
  end

  defp tuple_with_nil({_mod, fun, arity}), do: {nil, fun, arity}

  defp find_shared_data(project, target) do
    cg = project.call_graph

    if Graph.has_vertex?(cg, target) do
      project
      |> find_callers(target, 2)
      |> Enum.flat_map(&shared_data_for_caller(&1.id, cg, target))
      |> Enum.uniq()
      |> Enum.map(&Format.func_id_to_string/1)
    else
      []
    end
  end

  defp shared_data_for_caller(caller_id, cg, target) do
    Graph.out_neighbors(cg, caller_id)
    |> Enum.filter(&(&1 == target))
    |> Enum.map(fn _ -> caller_id end)
  end

  defp render_text(project, result) do
    target_str = Format.func_id_to_string(result.target)
    IO.puts("If you change #{target_str}:")

    render_caller_section(
      project,
      result.direct_callers,
      "Direct callers (break on signature change)"
    )

    render_caller_section(
      project,
      result.transitive_callers,
      "Transitive callers (break on behavior change)"
    )

    render_return_deps_section(result.return_dependents)
    render_risk_summary(result)
  end

  defp render_caller_section(project, callers, title) do
    IO.puts(Format.section(title))

    case callers do
      [] -> IO.puts("  " <> Format.empty())
      list -> Enum.each(list, &print_func_with_location(project, &1.id))
    end
  end

  defp render_return_deps_section(return_dependents) do
    IO.puts(Format.section("Return value dependents (break on output shape change)"))

    case return_dependents do
      [] ->
        IO.puts("  " <> Format.empty())

      deps ->
        Enum.each(deps, fn dep ->
          IO.puts("  #{Format.func_id_to_string(dep.in_function)} → #{dep.location}")
        end)
    end
  end

  defp render_risk_summary(result) do
    total = length(result.direct_callers) + length(result.transitive_callers)

    risk =
      cond do
        total > 8 -> "HIGH"
        total > 3 -> "MEDIUM"
        true -> "LOW"
      end

    IO.puts("\n#{total} affected function(s), risk: #{risk}\n")
  end

  defp print_func_with_location(project, func_id) do
    location = Project.func_location(project, func_id)
    IO.puts("  #{Format.func_id_to_string(func_id)}  #{location}")
  end

  defp render_oneline(result) do
    target_str = Format.func_id_to_string(result.target)

    Enum.each(result.direct_callers, fn %{id: id} ->
      IO.puts("#{target_str}:direct_caller:#{Format.func_id_to_string(id)}")
    end)

    Enum.each(result.transitive_callers, fn %{id: id} ->
      IO.puts("#{target_str}:transitive_caller:#{Format.func_id_to_string(id)}")
    end)
  end
end
