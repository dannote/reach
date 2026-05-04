defmodule Reach.ControlFlow do
  @moduledoc false

  alias Reach.IR.Node

  @type vertex :: Node.id() | :entry | :exit
  @type edge_label ::
          :sequential
          | :true_branch
          | :false_branch
          | {:clause_match, non_neg_integer()}
          | {:clause_fail, non_neg_integer()}
          | :guard_success
          | :guard_fail
          | :exception
          | :catch_entry
          | :after_entry
          | :timeout
          | :return

  @doc """
  Builds a control flow graph from a function definition IR node.

  Returns a `Graph.t()` with `:entry` and `:exit` as synthetic nodes.
  """
  @spec build(Node.t()) :: Graph.t()
  def build(%Node{type: :function_def} = node) do
    graph =
      Graph.new()
      |> Graph.add_vertex(:entry)
      |> Graph.add_vertex(:exit)

    clauses = node.children

    case clauses do
      [] ->
        Graph.add_edge(graph, :entry, :exit, label: :return)

      [single_clause] ->
        {graph, exits} = build_clause(graph, single_clause, :entry)
        connect_to_exit(graph, exits)

      multiple ->
        build_dispatch(graph, multiple)
    end
  end

  def build(%Node{type: :clause} = node) do
    graph =
      Graph.new()
      |> Graph.add_vertex(:entry)
      |> Graph.add_vertex(:exit)

    {graph, exits} = build_node(graph, node, :entry)
    connect_to_exit(graph, exits)
  end

  # --- Internal builders ---

  # Dispatch for multi-clause functions
  defp build_dispatch(graph, clauses) do
    dispatch_id = :dispatch

    graph = Graph.add_vertex(graph, dispatch_id)
    graph = Graph.add_edge(graph, :entry, dispatch_id, label: :sequential)

    {graph, _prev_fail} =
      Enum.with_index(clauses)
      |> Enum.reduce({graph, dispatch_id}, fn {clause, index}, {g, from} ->
        {g, clause_exits} = build_clause(g, clause, from, index)
        g = connect_to_exit(g, clause_exits)

        fail_node = {:clause_fail, index}
        g = Graph.add_vertex(g, fail_node)
        g = Graph.add_edge(g, from, fail_node, label: {:clause_fail, index})

        {g, fail_node}
      end)

    graph
  end

  defp build_clause(graph, node, from, index \\ 0)

  defp build_clause(graph, %Node{type: :clause} = clause, from, index) do
    children = clause.children

    {params, guards, body_nodes} = split_clause_children(children)

    graph = Graph.add_vertex(graph, clause.id)
    graph = Graph.add_edge(graph, from, clause.id, label: {:clause_match, index})

    # Build params (sequential)
    {graph, param_exits} = build_sequential(graph, params, clause.id)
    current = last_exit(param_exits)

    # Build guards
    {graph, current} = build_guards(graph, guards, current)

    # Build body
    build_sequential(graph, body_nodes, current)
  end

  defp build_clause(graph, %Node{} = node, from, _index) do
    build_node(graph, node, from)
  end

  defp build_node(graph, %Node{type: :block, children: children}, from) do
    build_sequential(graph, children, from)
  end

  defp build_node(graph, %Node{type: :case, children: [condition | clauses]} = node, from) do
    graph = Graph.add_vertex(graph, node.id)
    graph = Graph.add_edge(graph, from, node.id, label: :sequential)

    # Build condition
    graph = Graph.add_vertex(graph, condition.id)
    graph = Graph.add_edge(graph, node.id, condition.id, label: :sequential)

    # Build each clause
    build_clauses(graph, clauses, condition.id)
  end

  defp build_node(graph, %Node{type: :case, children: clauses} = node, from)
       when is_list(clauses) do
    graph = Graph.add_vertex(graph, node.id)
    graph = Graph.add_edge(graph, from, node.id, label: :sequential)

    build_clauses(graph, clauses, node.id)
  end

  defp build_node(graph, %Node{type: :try, children: children} = node, from) do
    graph = Graph.add_vertex(graph, node.id)
    graph = Graph.add_edge(graph, from, node.id, label: :sequential)

    # Split children into body, rescue, catch, after, else
    {body, rescue_clauses, catch_clauses, after_node, else_clauses} = split_try_children(children)

    # Build body
    {graph, body_exits} =
      case body do
        nil -> {graph, [node.id]}
        body_node -> build_node(graph, body_node, node.id)
      end

    {graph, rescue_exits} = build_exception_clauses(graph, rescue_clauses, node.id)
    {graph, catch_exits} = build_exception_clauses(graph, catch_clauses, node.id)

    all_exits =
      body_exits ++
        rescue_exits ++ catch_exits ++ else_clause_exits(graph, else_clauses, body_exits)

    # Build after (connects from all paths)
    case after_node do
      nil ->
        {graph, all_exits}

      %Node{} = after_n ->
        graph = Graph.add_vertex(graph, after_n.id)

        graph =
          Enum.reduce(all_exits, graph, fn exit_node, g ->
            Graph.add_edge(g, exit_node, after_n.id, label: :after_entry)
          end)

        {graph, after_exits} = build_sequential(graph, after_n.children, after_n.id)
        {graph, after_exits}
    end
  end

  defp build_node(graph, %Node{type: :receive, children: children} = node, from) do
    graph = Graph.add_vertex(graph, node.id)
    graph = Graph.add_edge(graph, from, node.id, label: :sequential)

    {clauses, timeout} =
      Enum.split_with(children, fn
        %Node{meta: %{kind: :timeout_clause}} -> false
        _ -> true
      end)

    {graph, clause_exits} = build_clauses(graph, clauses, node.id)

    # Build timeout clause
    {graph, timeout_exits} =
      case timeout do
        [] ->
          {graph, []}

        [timeout_clause] ->
          graph = Graph.add_vertex(graph, timeout_clause.id)
          graph = Graph.add_edge(graph, node.id, timeout_clause.id, label: :timeout)
          build_sequential(graph, timeout_clause.children, timeout_clause.id)
      end

    {graph, clause_exits ++ timeout_exits}
  end

  defp build_node(graph, %Node{type: :comprehension, children: children} = node, from) do
    graph = Graph.add_vertex(graph, node.id)
    graph = Graph.add_edge(graph, from, node.id, label: :sequential)

    # Generators and filters are sequential, body loops back
    build_sequential(graph, children, node.id)
  end

  defp build_node(graph, %Node{type: :fn, children: clauses} = node, from)
       when is_list(clauses) and clauses != [] do
    graph = Graph.add_vertex(graph, node.id)
    graph = Graph.add_edge(graph, from, node.id, label: :sequential)

    build_clauses(graph, clauses, node.id)
  end

  defp build_node(graph, %Node{type: :fn} = node, from) do
    graph = Graph.add_vertex(graph, node.id)
    graph = Graph.add_edge(graph, from, node.id, label: :sequential)
    {graph, [node.id]}
  end

  # Nodes with children that contain branches — process children, then add node as convergence
  defp build_node(graph, %Node{children: children} = node, from) when children != [] do
    if has_nested_branch?(node) do
      {graph, child_exits} = build_sequential(graph, children, from)
      graph = Graph.add_vertex(graph, node.id)

      graph =
        Enum.reduce(child_exits, graph, fn exit_v, g ->
          Graph.add_edge(g, exit_v, node.id, label: :sequential)
        end)

      {graph, [node.id]}
    else
      graph = Graph.add_vertex(graph, node.id)
      graph = Graph.add_edge(graph, from, node.id, label: :sequential)
      {graph, [node.id]}
    end
  end

  # Leaf nodes
  defp build_node(graph, %Node{} = node, from) do
    graph = Graph.add_vertex(graph, node.id)
    graph = Graph.add_edge(graph, from, node.id, label: :sequential)
    {graph, [node.id]}
  end

  defp has_nested_branch?(%Node{type: :case}), do: true
  defp has_nested_branch?(%Node{type: :try}), do: true
  defp has_nested_branch?(%Node{type: :receive}), do: true

  defp has_nested_branch?(%Node{children: children}),
    do: Enum.any?(children, &has_nested_branch?/1)

  # --- Helpers ---

  defp build_clauses(graph, clauses, parent_id) do
    {graph, exit_groups} =
      clauses
      |> Enum.with_index()
      |> Enum.reduce({graph, []}, fn {clause, index}, {g, exit_groups} ->
        {g, clause_exits} = build_clause(g, clause, parent_id, index)
        {g, [clause_exits | exit_groups]}
      end)

    {graph, exit_groups |> Enum.reverse() |> List.flatten()}
  end

  defp build_exception_clauses(graph, clauses, parent_id) do
    {graph, exit_groups} =
      Enum.reduce(clauses, {graph, []}, fn clause_node, {g, exit_groups} ->
        g = Graph.add_vertex(g, clause_node.id)
        g = Graph.add_edge(g, parent_id, clause_node.id, label: :exception)
        {g, clause_exits} = build_sequential(g, clause_node.children, clause_node.id)
        {g, [clause_exits | exit_groups]}
      end)

    {graph, exit_groups |> Enum.reverse() |> List.flatten()}
  end

  defp last_exit([single]), do: single
  defp last_exit([_ | rest]), do: last_exit(rest)

  defp build_sequential(graph, nodes, [current | extra]) do
    build_sequential(graph, nodes, current, extra)
  end

  defp build_sequential(graph, nodes, from) do
    build_sequential(graph, nodes, from, [])
  end

  defp build_sequential(graph, [], current, extra), do: {graph, [current | extra]}

  defp build_sequential(graph, [node | rest], current, extra_predecessors) do
    {graph, exits} = build_node(graph, node, current)

    first_vertex = first_cfg_vertex(graph, node)

    graph =
      Enum.reduce(extra_predecessors, graph, fn pred, g ->
        if first_vertex, do: Graph.add_edge(g, pred, first_vertex, label: :sequential), else: g
      end)

    case exits do
      [] -> {graph, [current | extra_predecessors]}
      [single] -> build_sequential(graph, rest, single, [])
      [next | extra] -> build_sequential(graph, rest, next, extra)
    end
  end

  defp first_cfg_vertex(graph, %Node{} = node) do
    if Graph.has_vertex?(graph, node.id), do: node.id, else: nil
  end

  defp build_guards(graph, guards, current) do
    Enum.reduce(guards, {graph, current}, fn guard, {g, prev} ->
      g = Graph.add_vertex(g, guard.id)
      g = Graph.add_edge(g, prev, guard.id, label: :guard_success)
      {g, guard.id}
    end)
  end

  defp connect_to_exit(graph, exits) do
    Enum.reduce(exits, graph, fn exit_node, g ->
      Graph.add_edge(g, exit_node, :exit, label: :return)
    end)
  end

  defp split_clause_children(children) do
    {params, rest} =
      Enum.split_while(children, fn
        %Node{type: :guard} -> false
        _ -> true
      end)

    {guards, body} =
      Enum.split_while(rest, fn
        %Node{type: :guard} -> true
        _ -> false
      end)

    # If there are no explicit body nodes after guards, treat last param as body
    # (single-expression function clause)
    case body do
      [] when params != [] ->
        {init, [last]} = Enum.split(params, -1)
        {init, guards, [last]}

      _ ->
        {params, guards, body}
    end
  end

  defp split_try_children(children) do
    body =
      Enum.find(children, fn
        %Node{type: t} when t in [:rescue, :catch_clause, :after, :clause] -> false
        _ -> true
      end)

    rescue_clauses = Enum.filter(children, &(&1.type == :rescue))
    catch_clauses = Enum.filter(children, &(&1.type == :catch_clause))

    after_node = Enum.find(children, &(&1.type == :after))

    else_clauses =
      Enum.filter(children, fn
        %Node{type: :clause} -> true
        _ -> false
      end)

    {body, rescue_clauses, catch_clauses, after_node, else_clauses}
  end

  defp else_clause_exits(_graph, [], _body_exits), do: []

  defp else_clause_exits(graph, else_clauses, body_exits) do
    # else clauses in try are handled after body succeeds
    {_graph, exits} =
      Enum.reduce(else_clauses, {graph, []}, fn clause, {g, exits} ->
        {g, c_exits} = build_sequential(g, clause.children, List.first(body_exits))
        {g, exits ++ c_exits}
      end)

    exits
  end
end
