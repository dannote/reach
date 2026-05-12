defmodule Reach.CLI.BoxartGraph do
  @moduledoc false

  alias Reach.CLI.Format
  alias Reach.CLI.Project
  alias Reach.IR
  alias Reach.Visualize.ControlFlow
  alias Reach.Visualize.Helpers

  @slice_node_render_limit 20

  @compile {:no_warn_undefined,
            [
              Boxart,
              Boxart.Render.StateDiagram,
              Boxart.Render.Mindmap,
              Boxart.Render.StateDiagram.State,
              Boxart.Render.StateDiagram.Transition,
              Boxart.Render.StateDiagram.StateDiagram,
              Boxart.Render.PieChart
            ]}

  @dialyzer {:nowarn_function,
             render_call_graph: 3,
             render_otp_state_diagram: 1,
             render_cfg: 2,
             render_caller_graph: 3,
             render_module_graph: 1,
             render_slice_graph: 3,
             render_boxart: 1,
             raise_missing!: 1}

  defp term_width do
    case :io.columns() do
      {:ok, cols} -> cols
      _ -> 120
    end
  end

  @max_terminal_cfg_nodes 80
  @install_hint "Add {:boxart, \"~> 0.3.3\"} to your deps."

  def available? do
    Code.ensure_loaded?(Boxart)
  end

  def require!(context \\ "--graph") do
    unless available?(), do: raise_missing!(context)
  end

  def require_state_diagram! do
    require!("OTP state diagrams")

    unless Code.ensure_loaded?(Boxart.Render.StateDiagram.State),
      do: raise_missing!("OTP state diagrams")
  end

  def require_pie_chart! do
    require!("effect graphs")

    unless Code.ensure_loaded?(Boxart.Render.PieChart) and
             Code.ensure_loaded?(Module.concat([Boxart, Render, PieChart, PieChart])),
           do: raise_missing!("effect graphs")
  end

  defp raise_missing!(context),
    do: Mix.raise("boxart is required for #{context}. #{@install_hint}")

  def render_call_graph(project, target, depth) do
    cg = project.call_graph
    variants = Project.all_variants(cg, target)

    {vertices, edges} = collect_subgraph(cg, variants, depth)

    graph =
      Enum.reduce(vertices, Graph.new(), fn v, g ->
        label = Format.func_id_to_string(v)
        style = if v in variants, do: [label: label, shape: :stadium], else: [label: label]
        Graph.add_vertex(g, v, style)
      end)

    graph = Enum.reduce(edges, graph, fn {from, to}, g -> Graph.add_edge(g, from, to) end)

    IO.puts(render_mindmap(graph))
  end

  def render_otp_state_diagram(callbacks) do
    require_state_diagram!()

    state_mod = Boxart.Render.StateDiagram.State
    transition_mod = Boxart.Render.StateDiagram.Transition
    diagram_mod = Boxart.Render.StateDiagram.StateDiagram

    states =
      [struct!(state_mod, id: "start", type: :start)] ++
        Enum.map(callbacks, fn %{callback: {name, arity}, action: action} ->
          struct!(state_mod, id: "#{name}/#{arity}", label: "#{name}/#{arity} (#{action})")
        end) ++
        [struct!(state_mod, id: "end", type: :end)]

    init_id =
      Enum.find_value(callbacks, fn
        %{callback: {:init, a}} -> "init/#{a}"
        _ -> nil
      end)

    transitions =
      if init_id do
        [struct!(transition_mod, from: "start", to: init_id)] ++
          Enum.flat_map(callbacks, fn %{callback: {name, arity}, action: action} ->
            id = "#{name}/#{arity}"

            if name != :init,
              do: [struct!(transition_mod, from: init_id, to: id, label: to_string(action))],
              else: []
          end) ++
          Enum.flat_map(callbacks, fn %{callback: {name, arity}} ->
            id = "#{name}/#{arity}"

            # credo:disable-for-next-line Credo.Check.Refactor.Nesting
            if name in [:terminate, :code_change],
              do: [struct!(transition_mod, from: id, to: "end")],
              else: []
          end)
      else
        []
      end

    diagram = struct!(diagram_mod, states: states, transitions: transitions)
    IO.puts(Boxart.Render.StateDiagram.render(diagram))
  end

  def render_cfg(func_node, file) do
    viz = ControlFlow.build_function(func_node, file)

    if length(viz.nodes) > @max_terminal_cfg_nodes do
      render_large_cfg_summary(viz, file)
    else
      graph =
        Enum.reduce(viz.nodes, Graph.new(), fn node, g ->
          Graph.add_vertex(g, node.id, viz_node_to_attrs(node, file))
        end)

      graph =
        Enum.reduce(viz.edges, graph, fn edge, g ->
          Graph.add_edge(g, edge.source, edge.target, edge_opts(edge))
        end)

      IO.puts(render_boxart(graph))
    end
  end

  def render_caller_graph(project, target, depth) do
    cg = project.call_graph
    variants = Project.all_variants(cg, target)

    # Collect callers by traversing in-neighbors (reverse direction)
    callers = collect_callers(cg, variants, depth)
    root_label = Format.func_id_to_string(target)

    graph = Graph.new() |> Graph.add_vertex(:root, label: root_label, shape: :stadium)

    graph =
      Enum.reduce(callers, graph, fn {caller, caller_depth}, g ->
        label = Format.func_id_to_string(caller)
        g = Graph.add_vertex(g, caller, label: label)

        if caller_depth == 1 do
          Graph.add_edge(g, :root, caller)
        else
          g
        end
      end)

    IO.puts(render_mindmap(graph))
  end

  defp collect_callers(cg, variants, depth) do
    collect_callers(cg, variants, depth, 1, MapSet.new(variants), [])
  end

  defp collect_callers(_cg, _frontier, max_depth, current, _visited, acc)
       when current > max_depth,
       do: acc

  defp collect_callers(cg, frontier, max_depth, current, visited, acc) do
    new_callers =
      frontier
      |> Enum.flat_map(fn v ->
        if Graph.has_vertex?(cg, v) do
          Graph.in_neighbors(cg, v) |> Enum.filter(&Project.mfa?/1)
        else
          []
        end
      end)
      |> Enum.reject(&MapSet.member?(visited, &1))
      |> Enum.uniq()

    new_acc = acc ++ Enum.map(new_callers, &{&1, current})
    new_visited = Enum.reduce(new_callers, visited, &MapSet.put(&2, &1))

    collect_callers(cg, new_callers, max_depth, current + 1, new_visited, new_acc)
  end

  def render_module_graph(project) do
    nodes = Map.values(project.nodes)

    # Group function_defs by file → module
    modules =
      nodes
      |> Enum.filter(&(&1.type == :module_def))
      |> Enum.uniq_by(& &1.meta[:name])

    # Only show edges between modules defined in this project
    internal = MapSet.new(modules, & &1.meta[:name])

    module_edges =
      modules
      |> Enum.flat_map(&module_deps(&1, internal))
      |> Enum.uniq()

    if module_edges == [] do
      IO.puts("  (no cross-module dependencies found)")
    else
      used_modules =
        module_edges
        |> Enum.flat_map(fn {from, to} -> [from, to] end)
        |> Enum.uniq()

      graph =
        Enum.reduce(used_modules, Graph.new(), fn mod, g ->
          Graph.add_vertex(g, mod, label: inspect(mod))
        end)

      graph =
        Enum.reduce(module_edges, graph, fn {from, to}, g ->
          Graph.add_edge(g, from, to)
        end)

      IO.puts(render_boxart(graph))
    end
  end

  def render_slice_graph(project, node_id, forward?) do
    graph = project.graph

    slice_ids =
      if Graph.has_vertex?(graph, node_id) do
        if forward? do
          Graph.reachable(graph, [node_id])
        else
          Graph.reaching(graph, [node_id])
        end
      else
        []
      end

    slice_nodes =
      slice_ids
      |> Enum.map(&Map.get(project.nodes, &1))
      |> Enum.reject(&is_nil/1)
      |> Enum.filter(& &1.source_span)
      |> Enum.take(@slice_node_render_limit)

    viz_graph =
      Enum.reduce(slice_nodes, Graph.new(), fn n, g ->
        label = slice_node_label(n)
        loc = n.source_span && "#{Path.basename(n.source_span.file)}:#{n.source_span.start_line}"
        Graph.add_vertex(g, n.id, label: "#{loc}\n#{label}")
      end)

    # Add edges from the project graph between slice nodes
    slice_id_set = MapSet.new(slice_nodes, & &1.id)

    viz_graph =
      MapSet.to_list(slice_id_set)
      |> Enum.flat_map(fn id ->
        if Graph.has_vertex?(graph, id) do
          Graph.out_edges(graph, id)
          |> Enum.filter(
            &(MapSet.member?(slice_id_set, &1.v1) and MapSet.member?(slice_id_set, &1.v2))
          )
          |> Enum.map(&{&1.v1, &1.v2})
        else
          []
        end
      end)
      |> Enum.uniq()
      |> Enum.reduce(viz_graph, fn {from, to}, g -> Graph.add_edge(g, from, to) end)

    IO.puts(render_boxart(viz_graph))
  end

  defp slice_node_label(%{type: :call, meta: %{module: m, function: f}}) when m != nil,
    do: "#{inspect(m)}.#{f}"

  defp slice_node_label(%{type: :call, meta: %{function: f}}), do: to_string(f)
  defp slice_node_label(%{type: :var, meta: %{name: n}}), do: to_string(n)
  defp slice_node_label(%{type: :match}), do: "="
  defp slice_node_label(%{type: t}), do: to_string(t)

  # credo:disable-for-next-line Credo.Check.Refactor.Apply
  defp render_mindmap(graph) do
    # credo:disable-for-next-line Credo.Check.Design.AliasUsage
    Boxart.Render.Mindmap.render(graph, [])
  end

  defp render_boxart(graph) do
    opts = [direction: :td, theme: :default, max_width: term_width()]
    Boxart.render(graph, opts)
  end

  defp render_large_cfg_summary(viz, file) do
    IO.puts(
      "CFG is too large for terminal rendering (#{length(viz.nodes)} blocks, #{length(viz.edges)} edges)."
    )

    IO.puts("Showing a compact block summary instead. Use the HTML report for the full graph.\n")

    viz.nodes
    |> Enum.sort_by(fn node -> {node.start_line || 0, node.id} end)
    |> Enum.take(@max_terminal_cfg_nodes)
    |> Enum.each(fn node ->
      label = node.label || to_string(node.type)
      location = line_range(file, node.start_line, node.end_line)
      IO.puts("  #{location} #{label}")
    end)

    remaining = length(viz.nodes) - @max_terminal_cfg_nodes

    if remaining > 0 do
      IO.puts("  " <> Format.omitted("#{remaining} more block(s) omitted"))
    end
  end

  defp line_range(file, start_line, end_line) do
    base = if file, do: Path.basename(file), else: "unknown"

    cond do
      is_integer(start_line) and is_integer(end_line) and start_line != end_line ->
        "#{base}:#{start_line}-#{end_line}"

      is_integer(start_line) ->
        "#{base}:#{start_line}"

      true ->
        base
    end
  end

  # ── Private ──

  defp edge_opts(%{label: label}) when label != "", do: [label: label]
  defp edge_opts(_), do: []

  defp module_deps(mod, internal) do
    mod_name = mod.meta[:name]

    mod
    |> IR.all_nodes()
    |> Enum.filter(&(&1.type == :call and &1.meta[:kind] == :remote and &1.meta[:module] != nil))
    |> Enum.map(& &1.meta[:module])
    |> Enum.filter(&(&1 != mod_name and MapSet.member?(internal, &1)))
    |> Enum.map(&{mod_name, &1})
  end

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
    case Helpers.cached_file_lines(file) do
      nil ->
        nil

      lines ->
        lines
        |> Enum.slice((start_line - 1)..(end_line - 1)//1)
        |> Helpers.dedent()
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
            Graph.out_neighbors(cg, v) |> Enum.filter(&Project.mfa?/1)
          else
            []
          end

        new_edges = Enum.map(out, &{v, &1})
        unvisited = Enum.reject(out, &MapSet.member?(vis, &1))
        {Enum.reverse(unvisited, front), MapSet.union(vis, MapSet.new(out)), Enum.reverse(new_edges, edg)}
      end)

    collect_subgraph(cg, new_frontier, depth - 1, new_visited, new_edges)
  end
end
