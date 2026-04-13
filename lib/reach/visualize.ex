defmodule Reach.Visualize do
  @moduledoc false

  @edge_colors %{
    data: "#3b82f6",
    control: "#f97316",
    containment: "#6b7280",
    call: "#8b5cf6",
    parameter_in: "#8b5cf6",
    parameter_out: "#8b5cf6",
    summary: "#8b5cf6",
    state_read: "#10b981",
    state_pass: "#10b981",
    match_binding: "#3b82f6",
    higher_order: "#ec4899",
    message_order: "#f59e0b",
    call_reply: "#f59e0b",
    monitor_down: "#ef4444",
    trap_exit: "#ef4444",
    link_exit: "#ef4444",
    task_result: "#f59e0b",
    startup_order: "#6b7280"
  }

  @node_colors %{
    module_def: "#6366f1",
    function_def: "#3b82f6",
    clause: "#64748b",
    call: "#f97316",
    var: "#10b981",
    literal: "#6b7280",
    match: "#8b5cf6",
    tuple: "#64748b",
    list: "#64748b",
    map: "#64748b",
    struct: "#8b5cf6",
    binary_op: "#f59e0b",
    unary_op: "#f59e0b",
    block: "#475569",
    case: "#f97316",
    cond: "#f97316",
    if: "#f97316",
    fn: "#3b82f6",
    comprehension: "#8b5cf6",
    try: "#ef4444",
    receive: "#f59e0b",
    map_field: "#64748b"
  }

  def to_vue_flow(graph, opts \\ [])

  def to_vue_flow(%Reach.Project{} = project, opts) do
    # For Project, use the merged graph and nodes
    sdg = %Reach.SystemDependence{
      graph: project.graph,
      nodes: project.nodes,
      function_pdgs: %{},
      call_graph: project.call_graph
    }

    to_vue_flow(sdg, opts)
  end

  def to_vue_flow(graph, opts) do
    all_nodes = Reach.nodes(graph)
    dead_ids = dead_ids(graph, opts)
    taint_ids = taint_ids(graph, opts)

    edges = Reach.edges(graph)

    parent_map = build_parent_map(all_nodes)
    levels = compute_levels(all_nodes, edges, parent_map)

    vue_nodes =
      all_nodes
      |> Enum.reject(&(&1.type in [:clause, :block]))
      |> Enum.map(fn node ->
        level = Map.get(levels, node.id, 0)
        sibling_index = sibling_index(node, all_nodes, levels)

        %{
          id: to_string(node.id),
          type: node_vue_type(node),
          position: %{x: sibling_index * 220, y: level * 120},
          data: node_data(node),
          style: node_style(node, dead_ids, taint_ids)
        }
        |> maybe_add_parent(node, parent_map)
      end)

    vue_edges =
      edges
      |> Enum.filter(fn e -> is_integer(e.v1) and is_integer(e.v2) end)
      |> Enum.map(fn e ->
        %{
          id: "e_#{e.v1}_#{e.v2}_#{edge_key(e.label)}",
          source: to_string(e.v1),
          target: to_string(e.v2),
          label: format_label(e.label),
          type: "smoothstep",
          animated: e.v1 in taint_ids and e.v2 in taint_ids,
          style: %{stroke: edge_color(e.label)}
        }
      end)

    %{nodes: vue_nodes, edges: vue_edges}
  end

  defp dead_ids(graph, opts) do
    if Keyword.get(opts, :dead_code, false) do
      graph |> Reach.dead_code() |> MapSet.new(& &1.id)
    else
      MapSet.new()
    end
  end

  defp taint_ids(graph, opts) do
    case Keyword.get(opts, :taint) do
      nil ->
        MapSet.new()

      taint_opts ->
        graph
        |> Reach.taint_analysis(taint_opts)
        |> Enum.flat_map(fn result ->
          [result.source.id, result.sink.id | Enum.map(result.path, & &1.id)]
        end)
        |> MapSet.new()
    end
  end

  defp node_vue_type(%{type: :function_def}), do: "function"
  defp node_vue_type(%{type: :module_def}), do: "module"
  defp node_vue_type(%{type: :call}), do: "call"
  defp node_vue_type(%{type: :var}), do: "var"
  defp node_vue_type(_), do: "default"

  defp node_data(node) do
    %{
      label: node_label(node),
      type: to_string(node.type),
      meta: sanitize_meta(node.meta),
      source_span: node.source_span
    }
  end

  defp node_label(%{type: :module_def, meta: %{name: name}}), do: "defmodule #{inspect(name)}"
  defp node_label(%{type: :function_def, meta: meta}), do: "def #{meta[:name]}/#{meta[:arity]}"

  defp node_label(%{type: :call, meta: meta}) do
    case meta[:module] do
      nil -> "#{meta[:function]}/#{meta[:arity]}"
      mod -> "#{inspect(mod)}.#{meta[:function]}/#{meta[:arity]}"
    end
  end

  defp node_label(%{type: :var, meta: %{name: name}}), do: to_string(name)
  defp node_label(%{type: :literal, meta: %{value: val}}), do: inspect(val)
  defp node_label(%{type: :match}), do: "="
  defp node_label(%{type: type}), do: to_string(type)

  defp node_style(node, dead_ids, taint_ids) do
    color = Map.get(@node_colors, node.type, "#64748b")
    opacity = if node.id in dead_ids, do: "0.3", else: "1"
    border_width = if node.id in taint_ids, do: "3px", else: "1px"
    border_color = if node.id in taint_ids, do: "#ef4444", else: color

    %{
      background: "#{color}15",
      borderColor: border_color,
      borderWidth: border_width,
      opacity: opacity,
      borderRadius: "8px",
      padding: "8px",
      fontSize: "12px"
    }
  end

  defp edge_color(label) when is_atom(label), do: Map.get(@edge_colors, label, "#64748b")

  defp edge_color({type, _}) when is_atom(type),
    do: Map.get(@edge_colors, type, "#64748b")

  defp edge_color(_), do: "#64748b"

  defp edge_key(label) when is_atom(label), do: label
  defp edge_key({type, _}), do: type
  defp edge_key(label), do: inspect(label)

  defp format_label(label) when is_atom(label), do: to_string(label)
  defp format_label({type, detail}), do: "#{type}: #{inspect(detail)}"
  defp format_label(label), do: inspect(label)

  defp sanitize_meta(meta) do
    meta
    |> Enum.map(fn {k, v} -> {to_string(k), sanitize_value(v)} end)
    |> Map.new()
  end

  defp sanitize_value(v) when is_atom(v), do: to_string(v)
  defp sanitize_value(v) when is_binary(v), do: v
  defp sanitize_value(v) when is_number(v), do: v
  defp sanitize_value(v) when is_boolean(v), do: v
  defp sanitize_value(nil), do: nil
  defp sanitize_value(v), do: inspect(v)

  defp build_parent_map(all_nodes) do
    for node <- all_nodes,
        child <- node.children,
        into: %{} do
      {child.id, node.id}
    end
  end

  defp compute_levels(all_nodes, _edges, parent_map) do
    Map.new(all_nodes, fn node ->
      level = count_ancestors(node.id, parent_map, 0)
      {node.id, level}
    end)
  end

  defp count_ancestors(id, parent_map, depth) do
    case Map.get(parent_map, id) do
      nil -> depth
      parent_id -> count_ancestors(parent_id, parent_map, depth + 1)
    end
  end

  defp sibling_index(node, all_nodes, levels) do
    my_level = Map.get(levels, node.id, 0)

    all_nodes
    |> Enum.filter(&(Map.get(levels, &1.id, 0) == my_level))
    |> Enum.sort_by(& &1.id)
    |> Enum.find_index(&(&1.id == node.id))
    |> Kernel.||(0)
  end

  defp maybe_add_parent(vue_node, %{type: type}, parent_map)
       when type not in [:module_def, :function_def] do
    case find_grouping_parent(Map.get(parent_map, vue_node.id |> String.to_integer()), parent_map) do
      nil -> vue_node
      parent_id -> Map.put(vue_node, :parentId, to_string(parent_id))
    end
  end

  defp maybe_add_parent(vue_node, _, _), do: vue_node

  defp find_grouping_parent(nil, _), do: nil
  defp find_grouping_parent(id, _parent_map) when is_integer(id), do: id

  def to_json(graph, opts \\ []) do
    unless Code.ensure_loaded?(Jason) do
      raise "Jason is required for JSON export. Add {:jason, \"~> 1.0\"} to your deps."
    end

    graph |> to_vue_flow(opts) |> Jason.encode!()
  end
end
