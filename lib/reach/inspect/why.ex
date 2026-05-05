defmodule Reach.Inspect.Why do
  @moduledoc "Finds and explains relationship paths between two targets."

  alias Reach.Inspect.Why.{Path, Result}
  alias Reach.IR
  alias Reach.IR.Helpers, as: IRHelpers
  alias Reach.Project.Query

  def result(project, source_raw, target_raw, max_depth) do
    source = resolve_why_target(project, source_raw)
    target = resolve_why_target(project, target_raw)

    cond do
      source == nil ->
        why_not_found(source_raw, target_raw, "source_not_found")

      target == nil ->
        why_not_found(source_raw, target_raw, "target_not_found")

      true ->
        source
        |> why_paths(project, target, max_depth)
        |> Map.from_struct()
        |> Map.merge(%{
          command: "reach.inspect",
          target: display_why_target(source),
          why: display_why_target(target)
        })
        |> Result.new()
    end
  end

  defp why_not_found(source_raw, target_raw, reason) do
    Result.new(
      command: "reach.inspect",
      target: source_raw,
      why: target_raw,
      relation: :none,
      paths: [],
      reason: reason
    )
  end

  defp why_paths(source, project, target, max_depth) do
    cond do
      source.kind == :function and target.kind == :function ->
        why_function_to_function(project, source.id, target.id, max_depth)

      source.kind == :function and target.kind == :module ->
        why_function_to_module(project, source.id, target.module, max_depth)

      source.kind == :module and target.kind == :module ->
        why_module_to_module(project, source.module, target.module, max_depth)

      source.kind == :module and target.kind == :function ->
        why_module_to_function(project, source.module, target.id, max_depth)
    end
  end

  defp why_function_to_function(project, source, target, max_depth) do
    sources = source_variants(project.call_graph, source)
    targets = target_variants(project.call_graph, target)

    case shortest_call_path(project.call_graph, sources, MapSet.new(targets), max_depth) do
      nil -> no_path_result(:call_path)
      path -> call_path_result(project, path)
    end
  end

  defp why_function_to_module(project, source, target_module, max_depth) do
    targets = function_vertices_for_module(project.call_graph, target_module)

    case shortest_call_path(
           project.call_graph,
           Query.all_variants(project.call_graph, source),
           MapSet.new(targets),
           max_depth
         ) do
      nil -> no_path_result(:call_path)
      path -> call_path_result(project, path)
    end
  end

  defp why_module_to_function(project, source_module, target, max_depth) do
    sources = function_vertices_for_module(project.call_graph, source_module)
    targets = MapSet.new(target_variants(project.call_graph, target))

    case shortest_call_path(project.call_graph, sources, targets, max_depth) do
      nil -> no_path_result(:call_path)
      path -> call_path_result(project, path)
    end
  end

  defp why_module_to_module(project, source_module, target_module, max_depth) do
    module_graph = module_dependency_graph(project)

    case shortest_module_path(module_graph, source_module, target_module, max_depth) do
      nil -> no_path_result(:module_dependency_path)
      path -> module_path_result(project, path)
    end
  end

  defp no_path_result(relation), do: Result.new(relation: relation, paths: [])

  defp call_path_result(project, path) do
    Result.new(
      relation: :call_path,
      paths: [
        Path.new(
          kind: :call,
          nodes: Enum.map(path, &function_path_node(project, &1)),
          evidence: call_path_evidence(project, path)
        )
      ]
    )
  end

  defp module_path_result(project, path) do
    Result.new(
      relation: :module_dependency_path,
      paths: [
        Path.new(
          kind: :module_dependency,
          nodes: Enum.map(path, &module_path_node(project, &1)),
          evidence: module_path_evidence(project, path)
        )
      ]
    )
  end

  defp source_variants(call_graph, {module, _fun, _arity} = mfa) when module != nil do
    call_graph
    |> Query.all_variants(mfa)
    |> Enum.sort_by(&if(&1 == mfa, do: 0, else: 1))
  end

  defp source_variants(call_graph, mfa), do: Query.all_variants(call_graph, mfa)

  defp target_variants(call_graph, {module, _fun, _arity} = mfa) when module != nil do
    if Graph.has_vertex?(call_graph, mfa), do: [mfa], else: Query.all_variants(call_graph, mfa)
  end

  defp target_variants(call_graph, mfa), do: Query.all_variants(call_graph, mfa)

  defp shortest_call_path(graph, sources, targets, max_depth) do
    sources
    |> Enum.filter(&Graph.has_vertex?(graph, &1))
    |> Enum.map(&[&1])
    |> bfs_path(graph, targets, max_depth, MapSet.new(sources))
  end

  defp shortest_module_path(graph, source, target, max_depth) do
    if Graph.has_vertex?(graph, source) and Graph.has_vertex?(graph, target) do
      bfs_path([[source]], graph, MapSet.new([target]), max_depth, MapSet.new([source]))
    end
  end

  defp bfs_path([], _graph, _targets, _max_depth, _visited), do: nil

  defp bfs_path([path | rest], graph, targets, max_depth, visited) do
    current = List.last(path)

    cond do
      current in targets ->
        path

      path_depth(path) > max_depth ->
        bfs_path(rest, graph, targets, max_depth, visited)

      true ->
        neighbors =
          graph
          |> Graph.out_neighbors(current)
          |> Enum.filter(&(why_vertex?(&1) and not MapSet.member?(visited, &1)))

        next_paths = Enum.map(neighbors, fn neighbor -> path ++ [neighbor] end)
        next_visited = Enum.reduce(neighbors, visited, &MapSet.put(&2, &1))
        bfs_path(rest ++ next_paths, graph, targets, max_depth, next_visited)
    end
  end

  defp path_depth(path), do: length(path)

  defp why_vertex?(vertex), do: Query.mfa?(vertex) or is_atom(vertex)

  defp resolve_why_target(project, raw) do
    parsed_file_line = Query.parse_file_line(raw)

    cond do
      parsed_file_line != nil ->
        {file, line} = parsed_file_line

        case Query.find_function_at_location(project, file, line) do
          nil -> nil
          func -> function_target({func.meta[:module], func.meta[:name], func.meta[:arity]})
        end

      mfa = Query.resolve_target(project, raw) ->
        function_target(mfa)

      module = resolve_module(project, raw) ->
        %{kind: :module, module: module}

      true ->
        nil
    end
  end

  defp function_target(mfa), do: %{kind: :function, id: mfa}

  defp resolve_module(project, raw) do
    project
    |> module_nodes()
    |> Enum.find_value(fn node ->
      module = node.meta[:name]
      module_name = module |> inspect() |> String.replace_leading("Elixir.", "")

      if module_name == raw or String.ends_with?(module_name, "." <> raw) do
        module
      end
    end)
  end

  defp display_why_target(%{kind: :function, id: id}), do: IRHelpers.func_id_to_string(id)
  defp display_why_target(%{kind: :module, module: module}), do: inspect(module)

  defp function_vertices_for_module(call_graph, module) do
    call_graph
    |> Graph.vertices()
    |> Enum.filter(fn
      {^module, _fun, _arity} -> true
      _ -> false
    end)
  end

  defp module_dependency_graph(project) do
    modules = module_nodes(project)
    internal = MapSet.new(modules, & &1.meta[:name])
    module_by_file = Map.new(modules, &{span_file(&1), &1.meta[:name]})

    Enum.reduce(modules, Graph.new(), fn module, graph ->
      graph
      |> Graph.add_vertex(module.meta[:name])
      |> add_module_dependency_edges(module, internal, module_by_file)
    end)
  end

  defp add_module_dependency_edges(graph, module, internal, module_by_file) do
    module
    |> IR.all_nodes()
    |> Enum.filter(&module_dependency_call?(&1, internal))
    |> Enum.reduce(graph, &add_module_dependency_edge(&1, &2, module_by_file))
  end

  defp add_module_dependency_edge(call, graph, module_by_file) do
    caller = call.source_span && Map.get(module_by_file, call.source_span.file)
    callee = call.meta[:module]

    if caller && callee && caller != callee,
      do: Graph.add_edge(graph, caller, callee),
      else: graph
  end

  defp module_dependency_call?(node, internal) do
    node.type == :call and node.meta[:kind] == :remote and node.meta[:module] != nil and
      node.meta[:function] not in [:__aliases__, :{}] and
      MapSet.member?(internal, node.meta[:module])
  end

  defp module_nodes(project) do
    for({_, node} <- project.nodes, node.type == :module_def, do: node)
    |> Enum.uniq_by(& &1.meta[:name])
  end

  defp function_path_node(project, mfa) do
    display_mfa = canonical_mfa(project, mfa)
    func = Query.find_function(project, display_mfa) || Query.find_function(project, mfa)

    %{
      function: IRHelpers.func_id_to_string(display_mfa),
      file: func && span_file(func),
      line: func && func.source_span && func.source_span.start_line
    }
  end

  defp module_path_node(project, module) do
    node = Enum.find(module_nodes(project), &(&1.meta[:name] == module))

    %{
      module: inspect(module),
      file: node && span_file(node),
      line: node && node.source_span && node.source_span.start_line
    }
  end

  defp call_path_evidence(project, path) do
    path
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.flat_map(fn [from, to] -> representative_call_evidence(project, from, to) end)
  end

  defp module_path_evidence(project, path) do
    path
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.flat_map(fn [from, to] -> representative_module_call_evidence(project, from, to) end)
  end

  defp representative_call_evidence(project, from, to) do
    source = canonical_mfa(project, from)

    with func when not is_nil(func) <- Query.find_function(project, source),
         call when not is_nil(call) <- Enum.find(IR.all_nodes(func), &call_matches_mfa?(&1, to)) do
      [
        evidence_from_call(call,
          from: IRHelpers.func_id_to_string(canonical_mfa(project, from)),
          to: IRHelpers.func_id_to_string(canonical_mfa(project, to))
        )
      ]
    else
      _ -> []
    end
  end

  defp representative_module_call_evidence(project, from, to) do
    project
    |> module_nodes()
    |> Enum.find(&(&1.meta[:name] == from))
    |> case do
      nil ->
        []

      module ->
        module
        |> IR.all_nodes()
        |> Enum.find(&call_matches_module?(&1, to))
        |> case do
          nil -> []
          call -> [evidence_from_call(call, from: inspect(from), to: inspect(to))]
        end
    end
  end

  defp evidence_from_call(call, edge) do
    %{
      from: edge[:from],
      to: edge[:to],
      call: IRHelpers.call_name(call),
      file: call.source_span && call.source_span.file,
      line: call.source_span && call.source_span.start_line,
      source: source_line(call)
    }
  end

  defp canonical_mfa(project, {nil, fun, arity} = mfa) do
    Enum.find_value(project.nodes, fn {_id, node} ->
      if node.type == :function_def and node.meta[:name] == fun and node.meta[:arity] == arity do
        {node.meta[:module], node.meta[:name], node.meta[:arity]}
      end
    end) || mfa
  end

  defp canonical_mfa(_project, mfa), do: mfa

  defp call_matches_mfa?(node, {_mod, fun, arity} = target) do
    node.type == :call and node.meta[:function] == fun and node.meta[:arity] == arity and
      (node.meta[:module] in [nil, elem(target, 0)] or elem(target, 0) == nil)
  end

  defp call_matches_module?(node, module) do
    node.type == :call and node.meta[:module] == module and
      node.meta[:function] not in [:__aliases__, :{}]
  end

  defp source_line(%{source_span: %{file: file, start_line: line}}) do
    case File.read(file) do
      {:ok, contents} ->
        contents |> String.split("\n") |> Enum.at(line - 1) |> to_string() |> String.trim()

      _ ->
        nil
    end
  end

  defp source_line(_node), do: nil

  defp span_file(node), do: node.source_span && node.source_span.file
end
