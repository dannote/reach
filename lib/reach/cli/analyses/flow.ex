defmodule Reach.CLI.Analyses.Flow do
  @moduledoc """
  Traces data flow from sources to sinks. Detects taint paths where
  untrusted input reaches dangerous operations.

      mix reach.flow --from conn.params --to Repo
      mix reach.flow --variable user --in UserService.register/2
      mix reach.flow --from conn.params --to System.cmd --format json

  ## Options

    * `--from` — taint source pattern (e.g. `conn.params`, `params`)
    * `--to` — sink pattern (e.g. `Repo`, `System.cmd`)
    * `--variable` — trace a specific variable name
    * `--in` — restrict to a specific function
    * `--format` — output format: `text` (default), `json`, `oneline`

  """

  @switches [
    format: :string,
    from: :string,
    to: :string,
    variable: :string,
    in: :string
  ]

  @aliases [f: :format]

  alias Reach.CLI.Format
  alias Reach.CLI.Project
  alias Reach.IR

  def run(args) do
    {opts, _args, _} = OptionParser.parse(args, switches: @switches, aliases: @aliases)
    format = opts[:format] || "text"

    project = Project.load()

    result =
      cond do
        opts[:from] && opts[:to] ->
          analyze_taint(project, opts[:from], opts[:to])

        opts[:variable] ->
          analyze_variable(project, opts[:variable], opts[:in])

        true ->
          Mix.raise("Provide --from/--to for taint analysis or --variable for data tracing")
      end

    case format do
      "json" -> Format.render(result, "reach.flow", format: "json", pretty: true)
      "oneline" -> render_oneline(result)
      _ -> render_text(project, result)
    end
  end

  defp analyze_taint(project, from_pattern, to_pattern) do
    sources = find_nodes(project, build_filter(from_pattern))
    sinks = find_nodes(project, build_filter(to_pattern))

    sdg = %Reach.SystemDependence{
      graph: project.graph,
      nodes: project.nodes,
      function_pdgs: %{},
      call_graph: project.call_graph
    }

    paths =
      for source <- sources,
          sink <- sinks,
          Reach.data_flows?(sdg, source.id, sink.id) do
        build_path(project, source, sink)
      end

    %{type: :taint, from: from_pattern, to: to_pattern, paths: paths}
  end

  defp analyze_variable(project, var_name, scope) do
    scope_nodes = resolve_scope_nodes(project, scope)

    definitions =
      Enum.filter(scope_nodes, fn n ->
        n.type == :var and n.meta[:binding_role] == :definition and
          to_string(n.meta[:name]) == var_name
      end)

    uses =
      Enum.filter(scope_nodes, fn n ->
        n.type == :var and n.meta[:binding_role] != :definition and
          to_string(n.meta[:name]) == var_name
      end)

    %{type: :variable, variable: var_name, definitions: definitions, uses: uses}
  end

  defp resolve_scope_nodes(project, nil), do: Map.values(project.nodes)

  defp resolve_scope_nodes(project, func_name) do
    nodes = Map.values(project.nodes)

    case Project.resolve_function(project, func_name) do
      nil ->
        nodes

      {mod, fun, arity} ->
        func_node =
          Enum.find(nodes, fn n ->
            n.type == :function_def and
              {n.meta[:module], n.meta[:name], n.meta[:arity]} == {mod, fun, arity}
          end)

        if func_node, do: IR.all_nodes(func_node), else: nodes
    end
  end

  defp build_filter(pattern) when pattern in ["conn.params", "params"] do
    fn node ->
      node.type == :var and node.meta[:name] in [:params, :user_params, :body_params]
    end
  end

  defp build_filter(pattern) when pattern in ["Repo", "Repo.query"] do
    fn node ->
      node.type == :call and
        ((is_atom(node.meta[:module]) and to_string(node.meta[:module]) =~ "Repo") or
           node.meta[:module] == Ecto.Adapters.SQL)
    end
  end

  defp build_filter("System.cmd") do
    fn node ->
      node.type == :call and node.meta[:module] == System and node.meta[:function] == :cmd
    end
  end

  defp build_filter(pattern) do
    fn node ->
      node.type == :call and to_string(node.meta[:function] || "") =~ pattern
    end
  end

  defp find_nodes(project, filter) do
    Map.values(project.nodes) |> Enum.filter(filter)
  end

  defp build_path(project, source, sink) do
    graph = project.graph

    if Graph.has_vertex?(graph, source.id) and Graph.has_vertex?(graph, sink.id) do
      fwd = Graph.reachable(graph, [source.id]) |> MapSet.new()
      bwd = Graph.reaching(graph, [sink.id]) |> MapSet.new()
      path_ids = MapSet.intersection(fwd, bwd) |> MapSet.to_list()

      path_nodes =
        path_ids
        |> Enum.map(fn id -> Map.get(project.nodes, id) end)
        |> Enum.reject(&is_nil/1)
        |> Enum.filter(& &1.source_span)
        |> Enum.sort_by(fn n -> {n.source_span[:file], n.source_span[:start_line]} end)
        |> Enum.uniq_by(fn n -> {n.source_span[:file], n.source_span[:start_line]} end)
        |> Enum.take(10)

      %{source: source, sink: sink, intermediate: path_nodes}
    else
      %{source: source, sink: sink, intermediate: []}
    end
  end

  defp render_text(project, result) do
    case result.type do
      :taint -> render_taint_text(project, result)
      :variable -> render_variable_text(result)
    end
  end

  defp render_taint_text(_project, result) do
    IO.puts(Format.header("Taint: #{result.from} → #{result.to}"))

    if result.paths == [] do
      IO.puts("\nNo data flow paths found.\n")
    else
      IO.puts("#{length(result.paths)} path(s) found:\n")
      result.paths |> Enum.with_index() |> Enum.each(&print_path/1)
    end
  end

  defp print_path({path, idx}) do
    IO.puts("Path #{idx + 1}:")
    IO.puts("  #{fmt_node(path.source)}")
    Enum.each(path.intermediate, fn node -> IO.puts("  #{fmt_node(node)}") end)
    IO.puts("  #{fmt_node(path.sink)}")
    IO.puts("")
  end

  defp render_variable_text(result) do
    IO.puts(Format.header("Variable: #{result.variable}"))

    IO.puts(Format.section("Definitions"))

    Enum.each(result.definitions, fn node ->
      IO.puts("  #{fmt_node(node)}")
    end)

    IO.puts(Format.section("Uses"))

    Enum.each(result.uses, fn node ->
      IO.puts("  #{fmt_node(node)}")
    end)
  end

  defp fmt_node(node) do
    loc = Format.location(node)

    desc =
      case node.type do
        :var -> "var #{node.meta[:name]}"
        :call -> "#{node.meta[:module] && inspect(node.meta[:module])}.#{node.meta[:function]}"
        other -> to_string(other)
      end

    "#{loc}  #{desc}"
  end

  defp render_oneline(result) do
    case result.type do
      :taint ->
        Enum.each(result.paths, fn path ->
          src = Format.location(path.source)
          snk = Format.location(path.sink)
          IO.puts("#{src} → #{snk}")
        end)

      :variable ->
        Enum.each(result.definitions, fn node ->
          IO.puts("def:#{Format.location(node)}:#{result.variable}")
        end)

        Enum.each(result.uses, fn node ->
          IO.puts("use:#{Format.location(node)}:#{result.variable}")
        end)
    end
  end
end
