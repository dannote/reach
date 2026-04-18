defmodule Reach.CLI.BoxartGraph do
  @moduledoc false

  alias Reach.CLI.Format

  defp term_width do
    case :io.columns() do
      {:ok, cols} -> cols
      _ -> 120
    end
  end

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

    graph = Enum.reduce(edges, graph, fn {from, to}, g -> Graph.add_edge(g, from, to) end)

    IO.puts(Boxart.Render.Mindmap.render(graph, []))
  end

  def render_otp_state_diagram(callbacks) do
    graph =
      Enum.reduce(callbacks, Graph.new(), fn %{callback: {name, arity}, action: action}, g ->
        label = "#{name}/#{arity}\n#{action}"
        Graph.add_vertex(g, {name, arity}, label: label, shape: :rounded)
      end)

    init = Enum.find(callbacks, fn %{callback: {name, _}} -> name == :init end)

    graph =
      if init do
        Enum.reduce(callbacks, graph, fn %{callback: {name, arity}}, g ->
          if name != :init, do: Graph.add_edge(g, init.callback, {name, arity}), else: g
        end)
      else
        graph
      end

    IO.puts(Boxart.render(graph, direction: :td, theme: :default, max_width: term_width()))
  end

  def render_cfg(func_node, file) do
    viz = Reach.Visualize.ControlFlow.build_function(func_node, file)

    graph =
      Enum.reduce(viz.nodes, Graph.new(), fn node, g ->
        Graph.add_vertex(g, node.id, viz_node_to_attrs(node, file))
      end)

    graph =
      Enum.reduce(viz.edges, graph, fn edge, g ->
        opts = if edge.label != "", do: [label: edge.label], else: []
        Graph.add_edge(g, edge.source, edge.target, opts)
      end)

    IO.puts(Boxart.render(graph, direction: :td, theme: :default, max_width: term_width()))
  end

  # ── Private ──

  defp viz_node_to_attrs(node, file) do
    case node.type do
      t when t in [:entry, :exit] ->
        [label: node.label, shape: :stadium]

      _ ->
        source = read_lines_range(file, node.start_line, node.end_line)

        if source do
          [source: source, start_line: node.start_line, language: :elixir]
        else
          [label: node.label || to_string(node.type)]
        end
    end
  end

  defp read_lines_range(file, start_line, end_line)
       when is_binary(file) and is_integer(start_line) and is_integer(end_line) do
    case Reach.Visualize.Helpers.cached_file_lines(file) do
      nil ->
        nil

      lines ->
        lines
        |> Enum.slice((start_line - 1)..(end_line - 1)//1)
        |> Enum.join("\n")
        |> String.trim()
        |> case do
          "" -> nil
          s -> s
        end
    end
  end

  defp read_lines_range(_, _, _), do: nil

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
end
