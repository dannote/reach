defmodule Reach.CLI.BoxartGraph do
  @moduledoc false

  alias Reach.CLI.Format

  def available? do
    Code.ensure_loaded?(Boxart)
  end

  def render_call_graph(project, target, depth) do
    cg = project.call_graph
    variants = Reach.CLI.Project.all_variants(cg, target)

    {vertices, edges} = collect_subgraph(cg, variants, depth)

    graph =
      Enum.reduce(vertices, Graph.new(), fn v, g ->
        label = Format.func_id_to_string(v)
        style = if v in variants, do: [label: label, shape: :stadium], else: [label: label]
        Graph.add_vertex(g, v, style)
      end)

    graph =
      Enum.reduce(edges, graph, fn {from, to}, g ->
        Graph.add_edge(g, from, to)
      end)

    IO.puts(Boxart.render(graph, direction: :lr, theme: :default))
  end

  def render_otp_state_diagram(callbacks) do
    graph = Graph.new()

    graph =
      Enum.reduce(callbacks, graph, fn %{callback: {name, arity}, action: action}, g ->
        label = to_string(name) <> "/" <> to_string(arity) <> "\n" <> to_string(action)
        Graph.add_vertex(g, {name, arity}, label: label, shape: :rounded)
      end)

    init = Enum.find(callbacks, fn %{callback: {name, _}} -> name == :init end)

    graph =
      if init do
        Enum.reduce(callbacks, graph, fn %{callback: {name, arity}}, g ->
          if name != :init do
            Graph.add_edge(g, init.callback, {name, arity})
          else
            g
          end
        end)
      else
        graph
      end

    IO.puts(Boxart.render(graph, direction: :td, theme: :default))
  end

  def render_cfg(func_node, file) do
    cfg = Reach.ControlFlow.build(func_node)

    vertices =
      cfg
      |> Graph.vertices()
      |> Enum.filter(fn v -> v != :entry and v != :exit end)

    node_map =
      func_node
      |> Reach.IR.all_nodes()
      |> Map.new(&{&1.id, &1})

    graph = Graph.new()

    graph =
      Enum.reduce([:entry | vertices] ++ [:exit], graph, fn v, g ->
        label = vertex_label(v, node_map, file)
        style = vertex_style(v)
        Graph.add_vertex(g, v, [{:label, label} | style])
      end)

    graph =
      cfg
      |> Graph.edges()
      |> Enum.reduce(graph, fn e, g ->
        label = edge_label(e.label)
        opts = if label, do: [label: label], else: []
        Graph.add_edge(g, e.v1, e.v2, opts)
      end)

    IO.puts(Boxart.render(graph, direction: :td, theme: :default))
  end

  # ── Helpers ──

  defp collect_subgraph(cg, roots, depth) do
    collect_subgraph(cg, roots, depth, MapSet.new(), [])
  end

  defp collect_subgraph(_cg, [], _depth, visited, edges), do: {visited, edges}
  defp collect_subgraph(_cg, _frontier, 0, visited, edges), do: {visited, edges}

  defp collect_subgraph(cg, frontier, depth, visited, edges) do
    {new_frontier, new_visited, new_edges} =
      Enum.reduce(frontier, {[], visited, edges}, fn v, {front, vis, edg} ->
        vis = MapSet.put(vis, v)

        out =
          if Graph.has_vertex?(cg, v) do
            Graph.out_neighbors(cg, v) |> Enum.filter(&Reach.CLI.Project.mfa?/1)
          else
            []
          end

        new_edges = Enum.map(out, &{v, &1})

        unvisited = Enum.reject(out, &MapSet.member?(vis, &1))
        {front ++ unvisited, MapSet.union(vis, MapSet.new(out)), edg ++ new_edges}
      end)

    collect_subgraph(cg, new_frontier, depth - 1, new_visited, new_edges)
  end

  defp vertex_label(:entry, _node_map, _file), do: "entry"
  defp vertex_label(:exit, _node_map, _file), do: "exit"

  defp vertex_label(v, node_map, file) when is_integer(v) do
    case Map.get(node_map, v) do
      nil ->
        inspect(v)

      node ->
        line = node.source_span && node.source_span.start_line

        if line && file do
          case Reach.Visualize.Helpers.read_line(file, line) do
            nil -> ir_label(node)
            text -> String.trim(text)
          end
        else
          ir_label(node)
        end
    end
  end

  defp vertex_label(v, _node_map, _file), do: inspect(v)

  defp vertex_style(:entry), do: [shape: :stadium]
  defp vertex_style(:exit), do: [shape: :stadium]
  defp vertex_style(_), do: []

  defp edge_label(:sequential), do: nil
  defp edge_label(:true_branch), do: "true"
  defp edge_label(:false_branch), do: "false"
  defp edge_label({:clause_match, _}), do: "match"
  defp edge_label({:clause_fail, _}), do: "fail"
  defp edge_label(:return), do: "return"
  defp edge_label(:guard_success), do: "guard ok"
  defp edge_label(:guard_fail), do: "guard fail"
  defp edge_label(_), do: nil

  defp ir_label(%{type: :call, meta: %{function: f, module: m}}) when m != nil,
    do: "#{inspect(m)}.#{f}"

  defp ir_label(%{type: :call, meta: %{function: f}}), do: to_string(f)
  defp ir_label(%{type: :case, meta: %{desugared_from: :if}}), do: "if"
  defp ir_label(%{type: :case, meta: %{desugared_from: :cond}}), do: "cond"
  defp ir_label(%{type: :case}), do: "case"
  defp ir_label(%{type: :var, meta: %{name: n}}), do: to_string(n)
  defp ir_label(%{type: :match}), do: "="
  defp ir_label(%{type: :binary_op, meta: %{operator: op}}), do: to_string(op)
  defp ir_label(%{type: t}), do: to_string(t)
end
