defmodule Reach.Concurrency do
  @moduledoc false

  alias Reach.IR
  alias Reach.IR.Node

  @doc """
  Analyzes IR nodes for concurrency patterns and returns a graph with
  concurrency-specific edges.
  """
  @spec analyze([Node.t()], keyword()) :: Graph.t()
  def analyze(ir_nodes, opts \\ []) do
    all_nodes = Keyword.get_lazy(opts, :all_nodes, fn -> IR.all_nodes(ir_nodes) end)

    module_map = build_module_map(all_nodes)

    Graph.new()
    |> add_monitor_edges(all_nodes)
    |> add_trap_exit_edges(all_nodes, module_map)
    |> add_spawn_link_edges(all_nodes)
    |> add_task_edges(all_nodes, module_map)
    |> add_supervisor_edges(all_nodes)
  end

  # --- Monitor → :DOWN ---

  defp add_monitor_edges(graph, all_nodes) do
    monitors = Enum.filter(all_nodes, &monitor_call?/1)
    down_handlers = find_down_handlers(all_nodes)

    for monitor <- monitors,
        handler <- down_handlers,
        reduce: graph do
      g ->
        g
        |> Graph.add_vertex(monitor.id)
        |> Graph.add_vertex(handler.id)
        |> Graph.add_edge(monitor.id, handler.id, label: :monitor_down)
    end
  end

  defp monitor_call?(%Node{type: :call, meta: %{module: Process, function: :monitor}}), do: true
  defp monitor_call?(_), do: false

  defp find_down_handlers(all_nodes) do
    all_nodes
    |> Enum.filter(fn node ->
      node.type == :function_def and
        node.meta[:name] == :handle_info and
        has_down_pattern?(node)
    end)
  end

  defp has_down_pattern?(func_def) do
    func_def
    |> IR.all_nodes()
    |> Enum.any?(fn node ->
      node.type == :literal and node.meta[:value] == :DOWN
    end)
  end

  # --- trap_exit → :EXIT ---

  defp add_trap_exit_edges(graph, all_nodes, module_map) do
    trap_calls = Enum.filter(all_nodes, &trap_exit_call?/1)
    exit_handlers = find_exit_handlers(all_nodes)

    for trap <- trap_calls,
        handler <- exit_handlers,
        same_module?(module_map, trap, handler),
        reduce: graph do
      g ->
        g
        |> Graph.add_vertex(trap.id)
        |> Graph.add_vertex(handler.id)
        |> Graph.add_edge(trap.id, handler.id, label: :trap_exit)
    end
  end

  defp trap_exit_call?(%Node{type: :call, meta: %{module: Process, function: :flag}} = node) do
    case node.children do
      [%Node{type: :literal, meta: %{value: :trap_exit}} | _] -> true
      _ -> false
    end
  end

  defp trap_exit_call?(_), do: false

  defp find_exit_handlers(all_nodes) do
    Enum.filter(all_nodes, fn node ->
      node.type == :function_def and
        node.meta[:name] == :handle_info and
        has_exit_pattern?(node)
    end)
  end

  defp has_exit_pattern?(func_def) do
    func_def
    |> IR.all_nodes()
    |> Enum.any?(fn node ->
      node.type == :literal and node.meta[:value] == :EXIT
    end)
  end

  # --- spawn_link / Link ---

  defp add_spawn_link_edges(graph, all_nodes) do
    spawn_links = Enum.filter(all_nodes, &spawn_link_call?/1)
    link_calls = Enum.filter(all_nodes, &link_call?/1)

    all_links = spawn_links ++ link_calls
    exit_handlers = find_exit_handlers(all_nodes)

    for link <- all_links,
        handler <- exit_handlers,
        reduce: graph do
      g ->
        g
        |> Graph.add_vertex(link.id)
        |> Graph.add_vertex(handler.id)
        |> Graph.add_edge(link.id, handler.id, label: :link_exit)
    end
  end

  defp spawn_link_call?(%Node{type: :call, meta: %{function: :spawn_link}}), do: true
  defp spawn_link_call?(_), do: false

  defp link_call?(%Node{type: :call, meta: %{module: Process, function: :link}}), do: true
  defp link_call?(_), do: false

  # --- Task.async → Task.await ---

  defp add_task_edges(graph, all_nodes, module_map) do
    asyncs = Enum.filter(all_nodes, &task_async?/1)
    awaits = Enum.filter(all_nodes, &task_await?/1)

    # Pair asyncs with awaits in the same function by position order.
    # Within a function, the Nth async typically pairs with the Nth await.
    # Falls back to cartesian product only across function boundaries.
    paired = pair_by_scope(asyncs, awaits, module_map)

    Enum.reduce(paired, graph, fn {async, await}, g ->
      g
      |> Graph.add_vertex(async.id)
      |> Graph.add_vertex(await.id)
      |> Graph.add_edge(async.id, await.id, label: :task_result)
    end)
  end

  defp pair_by_scope(asyncs, awaits, module_map) do
    # Group by enclosing module
    async_by_mod = Enum.group_by(asyncs, &Map.get(module_map, &1.id))
    await_by_mod = Enum.group_by(awaits, &Map.get(module_map, &1.id))

    modules = Map.keys(async_by_mod) |> Enum.filter(&Map.has_key?(await_by_mod, &1))

    Enum.flat_map(modules, fn mod ->
      mod_asyncs = Map.get(async_by_mod, mod, []) |> Enum.sort_by(& &1.id)
      mod_awaits = Map.get(await_by_mod, mod, []) |> Enum.sort_by(& &1.id)
      Enum.zip(mod_asyncs, mod_awaits)
    end)
  end

  defp task_async?(%Node{type: :call, meta: %{module: Task, function: f}})
       when f in [:async, :async_stream],
       do: true

  defp task_async?(_), do: false

  defp task_await?(%Node{type: :call, meta: %{module: Task, function: f}})
       when f in [:await, :await_many, :yield, :yield_many],
       do: true

  defp task_await?(_), do: false

  # --- Supervisor children ---

  defp add_supervisor_edges(graph, all_nodes) do
    # Find init/1 functions that return child specs
    init_funcs =
      Enum.filter(all_nodes, fn node ->
        node.type == :function_def and
          node.meta[:name] == :init and
          node.meta[:arity] == 1
      end)

    Enum.reduce(init_funcs, graph, fn init_func, g ->
      children = extract_child_modules(init_func)
      add_child_order_edges(g, children)
    end)
  end

  defp extract_child_modules(init_func) do
    init_func
    |> IR.all_nodes()
    |> Enum.filter(fn node ->
      # Look for list literals containing module references or tuples
      # These are typically the children list in Supervisor.init
      node.type == :list and
        Enum.any?(node.children, &child_spec_like?/1)
    end)
    |> Enum.flat_map(fn list_node ->
      Enum.map(list_node.children, &extract_child_module/1)
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp child_spec_like?(%Node{type: :call, meta: %{kind: :local, function: :__aliases__}}),
    do: true

  defp child_spec_like?(%Node{type: :tuple}), do: true
  defp child_spec_like?(%Node{type: :literal, meta: %{value: v}}) when is_atom(v), do: true
  defp child_spec_like?(_), do: false

  defp extract_child_module(%Node{type: :literal, meta: %{value: mod}}) when is_atom(mod),
    do: {mod, nil}

  defp extract_child_module(%Node{type: :call, meta: %{function: :__aliases__}} = node) do
    # Alias like MyApp.Worker
    case node.children do
      [%Node{type: :literal, meta: %{value: name}} | _] -> {name, node.id}
      _ -> nil
    end
  end

  defp extract_child_module(%Node{type: :tuple, children: [first | _]}) do
    case first do
      %Node{type: :literal, meta: %{value: mod}} when is_atom(mod) -> {mod, first.id}
      %Node{type: :call, meta: %{function: :__aliases__}} -> extract_child_module(first)
      _ -> nil
    end
  end

  defp extract_child_module(_), do: nil

  defp add_child_order_edges(graph, []), do: graph
  defp add_child_order_edges(graph, [_single]), do: graph

  defp add_child_order_edges(graph, children) do
    children
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.reduce(graph, fn [{_mod_a, id_a}, {_mod_b, id_b}], g ->
      if id_a && id_b do
        g
        |> Graph.add_vertex(id_a)
        |> Graph.add_vertex(id_b)
        |> Graph.add_edge(id_a, id_b, label: :startup_order)
      else
        g
      end
    end)
  end

  # --- Helpers ---

  defp build_module_map(all_nodes) do
    all_nodes
    |> Enum.filter(&(&1.type == :module_def))
    |> Enum.reduce(%{}, fn mod_def, acc ->
      mod_def
      |> IR.all_nodes()
      |> Enum.reduce(acc, &Map.put_new(&2, &1.id, mod_def.meta[:name]))
    end)
  end

  defp same_module?(module_map, node_a, node_b) do
    mod_a = Map.get(module_map, node_a.id)
    mod_b = Map.get(module_map, node_b.id)
    mod_a != nil and mod_a == mod_b
  end
end
