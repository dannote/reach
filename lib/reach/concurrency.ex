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

    Graph.new()
    |> add_monitor_edges(all_nodes)
    |> add_trap_exit_edges(all_nodes)
    |> add_spawn_link_edges(all_nodes)
    |> add_task_edges(all_nodes)
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

  defp add_trap_exit_edges(graph, all_nodes) do
    trap_calls = Enum.filter(all_nodes, &trap_exit_call?/1)
    exit_handlers = find_exit_handlers(all_nodes)

    for trap <- trap_calls,
        handler <- exit_handlers,
        same_module?(all_nodes, trap, handler),
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

    exit_handlers =
      all_nodes
      |> Enum.filter(fn node ->
        node.type == :function_def and
          node.meta[:name] == :handle_info
      end)

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

  defp add_task_edges(graph, all_nodes) do
    asyncs = Enum.filter(all_nodes, &task_async?/1)
    awaits = Enum.filter(all_nodes, &task_await?/1)

    for async <- asyncs,
        await <- awaits,
        reduce: graph do
      g ->
        g
        |> Graph.add_vertex(async.id)
        |> Graph.add_vertex(await.id)
        |> Graph.add_edge(async.id, await.id, label: :task_result)
    end
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

  defp add_child_order_edges(graph, children) when length(children) < 2, do: graph

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

  defp same_module?(all_nodes, node_a, node_b) do
    func_a = find_enclosing_module(all_nodes, node_a.id)
    func_b = find_enclosing_module(all_nodes, node_b.id)
    func_a != nil and func_a == func_b
  end

  defp find_enclosing_module(all_nodes, target_id) do
    Enum.find_value(all_nodes, fn
      %Node{type: :module_def, meta: %{name: name}} = mod ->
        if node_in_subtree?(mod, target_id), do: name

      _ ->
        nil
    end)
  end

  defp node_in_subtree?(%Node{id: id}, target) when id == target, do: true

  defp node_in_subtree?(%Node{children: children}, target) do
    Enum.any?(children, &node_in_subtree?(&1, target))
  end
end
