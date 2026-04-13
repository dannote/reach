defmodule Reach.Project do
  @moduledoc """
  Multi-file project analysis.

  Builds graphs for all source files in a project, links cross-module
  call edges, and applies external function summaries for dependencies.

  ## Examples

      # Analyze a full Mix project
      project = Reach.Project.from_mix_project()

      # Analyze specific paths
      project = Reach.Project.from_glob("lib/**/*.ex")

      # Query across the whole project
      Reach.Project.taint_analysis(project,
        sources: [type: :call, function: :params],
        sinks: [type: :call, module: System, function: :cmd]
      )
  """

  alias Reach.{Frontend, IR}

  @type t :: %__MODULE__{
          modules: %{module() => Reach.SystemDependence.t()},
          graph: Graph.t(),
          nodes: %{IR.Node.id() => IR.Node.t()},
          call_graph: Graph.t(),
          summaries: %{Reach.CallGraph.function_id() => map()}
        }

  @enforce_keys [:modules, :graph, :nodes, :call_graph]
  defstruct [:modules, :graph, :nodes, :call_graph, summaries: %{}]

  @doc """
  Builds a project graph from source file paths.
  """
  @spec from_sources([Path.t()], keyword()) :: t()
  def from_sources(paths, opts \\ []) do
    module_sdgs =
      paths
      |> parse_files(opts)
      |> build_module_sdgs(opts)

    merge_project(module_sdgs, opts)
  end

  @doc """
  Builds a project graph from a glob pattern.
  """
  @spec from_glob(String.t(), keyword()) :: t()
  def from_glob(pattern, opts \\ []) do
    pattern
    |> Path.wildcard()
    |> Enum.sort()
    |> from_sources(opts)
  end

  @doc """
  Builds a project graph from the current Mix project.

  Analyzes all `.ex` files in `lib/` and all `.erl` files in `src/`.
  """
  @spec from_mix_project(keyword()) :: t()
  def from_mix_project(opts \\ []) do
    elixir_files = Path.wildcard("lib/**/*.ex")
    erlang_files = Path.wildcard("src/**/*.erl")

    from_sources(elixir_files ++ erlang_files, opts)
  end

  @doc """
  Computes a function summary for a compiled dependency module.

  Returns a map of `{module, function, arity} => %{param_index => flows_to_return?}`.
  These summaries can be passed as the `:summaries` option to `from_sources/2`.
  """
  @spec summarize_dependency(module()) :: %{Reach.CallGraph.function_id() => map()}
  def summarize_dependency(module) do
    case Frontend.BEAM.from_module(module) do
      {:ok, ir_nodes} ->
        all = IR.all_nodes(ir_nodes)

        all
        |> Enum.filter(&(&1.type == :function_def))
        |> Map.new(fn func_def ->
          func_id = {module, func_def.meta[:name], func_def.meta[:arity]}
          {func_id, compute_param_flows(func_def)}
        end)

      {:error, _} ->
        %{}
    end
  end

  @doc """
  Runs taint analysis across the entire project.

  Same interface as `Reach.taint_analysis/2` but searches all modules.
  """
  @spec taint_analysis(t(), keyword()) :: [map()]
  def taint_analysis(%__MODULE__{nodes: nodes} = project, opts) do
    source_filter = Keyword.fetch!(opts, :sources)
    sink_filter = Keyword.fetch!(opts, :sinks)
    sanitizer_filter = Keyword.get(opts, :sanitizers)

    all = Map.values(nodes)
    sources = filter_by(all, source_filter)
    sinks = filter_by(all, sink_filter)

    for source <- sources,
        sink <- sinks,
        data_flows_in_graph?(project.graph, source.id, sink.id) do
      path = chop_in_graph(project.graph, source.id, sink.id)

      sanitized =
        sanitizer_filter != nil and
          path_matches_filter?(path, nodes, sanitizer_filter)

      %{source: source, sink: sink, path: path, sanitized: sanitized}
    end
  end

  defp path_matches_filter?(path, nodes, filter) do
    Enum.any?(path, fn id ->
      case Map.get(nodes, id) do
        nil -> false
        node -> matches_filter?(node, filter)
      end
    end)
  end

  defp data_flows_in_graph?(graph, source_id, sink_id) do
    if Graph.has_vertex?(graph, source_id) do
      sink_id in Graph.reachable(graph, [source_id])
    else
      false
    end
  end

  defp chop_in_graph(graph, source_id, sink_id) do
    fwd =
      if Graph.has_vertex?(graph, source_id),
        do: Graph.reachable(graph, [source_id]) |> MapSet.new(),
        else: MapSet.new()

    bwd =
      if Graph.has_vertex?(graph, sink_id),
        do: Graph.reaching(graph, [sink_id]) |> MapSet.new(),
        else: MapSet.new()

    MapSet.intersection(fwd, bwd)
    |> MapSet.delete(source_id)
    |> MapSet.delete(sink_id)
    |> MapSet.to_list()
  end

  defp filter_by(nodes, filter) when is_list(filter) do
    Enum.filter(nodes, fn node -> Enum.all?(filter, &matches_kv?(node, &1)) end)
  end

  defp filter_by(nodes, filter) when is_function(filter), do: Enum.filter(nodes, filter)

  defp matches_kv?(node, {:type, type}), do: node.type == type
  defp matches_kv?(node, {:module, mod}), do: node.meta[:module] == mod
  defp matches_kv?(node, {:function, fun}), do: node.meta[:function] == fun
  defp matches_kv?(node, {:arity, arity}), do: node.meta[:arity] == arity
  defp matches_kv?(_, _), do: true

  defp matches_filter?(node, filter) when is_list(filter),
    do: Enum.all?(filter, &matches_kv?(node, &1))

  defp matches_filter?(node, filter) when is_function(filter), do: filter.(node)

  # --- Private ---

  defp parse_files(paths, _opts) do
    paths
    |> Task.async_stream(
      fn path ->
        language = language_from_path(path)
        module_name = module_from_path(path)

        result =
          case language do
            :erlang -> Frontend.Erlang.parse_file(path, file: path)
            :elixir -> parse_elixir_file(path)
          end

        case result do
          {:ok, ir_nodes} -> {module_name, path, ir_nodes}
          {:error, _} -> nil
        end
      end,
      max_concurrency: System.schedulers_online(),
      ordered: false
    )
    |> Enum.flat_map(fn
      {:ok, nil} -> []
      {:ok, result} -> [result]
    end)
  end

  defp parse_elixir_file(path) do
    case File.read(path) do
      {:ok, source} -> Frontend.Elixir.parse(source, file: path)
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_module_sdgs(parsed_modules, opts) do
    summaries = Keyword.get(opts, :summaries, %{})

    Map.new(parsed_modules, fn {module_name, _path, ir_nodes} ->
      sdg =
        Reach.SystemDependence.build(ir_nodes,
          module: module_name,
          summaries: summaries
        )

      {module_name, sdg}
    end)
  end

  defp merge_project(module_sdgs, opts) do
    summaries = Keyword.get(opts, :summaries, %{})

    # Collect all function defs across modules for cross-module resolution
    external_sdgs = build_external_sdg_map(module_sdgs)

    # Rebuild each module's SDG with cross-module resolution
    module_sdgs =
      Map.new(module_sdgs, fn {mod, sdg} ->
        all_nodes = Map.values(sdg.nodes)
        func_defs = Reach.CallGraph.collect_function_defs(all_nodes, mod)

        # Re-add call edges with cross-module awareness
        graph =
          Reach.SystemDependence.add_call_edges_with_externals(
            sdg.graph,
            all_nodes,
            func_defs,
            external_sdgs: external_sdgs,
            summaries: summaries
          )

        {mod, %{sdg | graph: graph}}
      end)

    # Merge all graphs
    merged_graph =
      module_sdgs
      |> Map.values()
      |> Enum.reduce(Graph.new(), fn sdg, acc ->
        Graph.add_edges(acc, Graph.edges(sdg.graph))
      end)

    merged_nodes =
      module_sdgs
      |> Map.values()
      |> Enum.reduce(%{}, fn sdg, acc -> Map.merge(acc, sdg.nodes) end)

    merged_call_graph =
      module_sdgs
      |> Map.values()
      |> Enum.reduce(Graph.new(), fn sdg, acc ->
        Graph.add_edges(acc, Graph.edges(sdg.call_graph))
      end)

    %__MODULE__{
      modules: module_sdgs,
      graph: merged_graph,
      nodes: merged_nodes,
      call_graph: merged_call_graph,
      summaries: summaries
    }
  end

  defp build_external_sdg_map(module_sdgs) do
    for {_mod, sdg} <- module_sdgs,
        {func_id, pdg} <- sdg.function_pdgs,
        func_def = find_func_def(pdg),
        func_def != nil,
        into: %{} do
      {func_id, %{func_def: func_def, pdg: pdg}}
    end
  end

  defp find_func_def(pdg) do
    pdg.nodes |> Map.values() |> Enum.find(&(&1.type == :function_def))
  end

  defp compute_param_flows(func_def) do
    case func_def.children do
      [%{type: :clause, children: children, meta: %{kind: :function_clause}} | _] ->
        arity = func_def.meta[:arity] || 0
        params = Enum.take(children, arity)
        return_nodes = find_return_expressions(func_def)

        params
        |> Enum.with_index()
        |> Map.new(fn {param, index} ->
          var_name = param_var_name(param)

          flows =
            var_name != nil and
              Enum.any?(return_nodes, &var_used_in_subtree?(&1, var_name))

          {index, flows}
        end)

      _ ->
        %{}
    end
  end

  defp find_return_expressions(func_def) do
    func_def
    |> IR.all_nodes()
    |> Enum.filter(&(&1.type == :clause and &1.meta[:kind] == :function_clause))
    |> Enum.flat_map(fn clause ->
      case List.last(clause.children) do
        nil -> []
        last -> [last]
      end
    end)
  end

  defp param_var_name(%IR.Node{type: :var, meta: %{name: name}}), do: name
  defp param_var_name(_), do: nil

  defp var_used_in_subtree?(%IR.Node{type: :var, meta: %{name: name}}, target), do: name == target

  defp var_used_in_subtree?(%IR.Node{children: children}, target) do
    Enum.any?(children, &var_used_in_subtree?(&1, target))
  end

  defp language_from_path(path) do
    case Path.extname(path) do
      ext when ext in [".erl", ".hrl"] -> :erlang
      _ -> :elixir
    end
  end

  defp module_from_path(path) do
    path
    |> Path.rootname()
    |> Path.split()
    |> Enum.drop_while(&(&1 != "lib" and &1 != "src"))
    |> Enum.drop(1)
    |> Enum.map_join(".", &Macro.camelize/1)
    |> then(fn
      "" -> nil
      name -> Module.concat([name])
    end)
  end
end
