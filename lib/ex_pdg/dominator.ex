defmodule ExPDG.Dominator do
  @moduledoc """
  Dominator and post-dominator tree computation.

  Implements the iterative data-flow algorithm for computing dominators.
  While Lengauer-Tarjan is asymptotically faster, the iterative algorithm
  is simpler, correct, and fast enough for function-level CFGs (typically
  < 100 nodes).

  ## References
  - Cooper, Harvey, Kennedy: "A Simple, Fast Dominance Algorithm" (2001)
  """

  @doc """
  Computes the immediate dominator map for a directed graph.

  Returns `%{vertex => immediate_dominator}`. The root vertex maps to itself.
  """
  @spec idom(Graph.t(), term()) :: %{term() => term()}
  def idom(graph, root) do
    vertices = reverse_postorder(graph, root)
    index = vertices |> Enum.with_index() |> Map.new()

    # Initialize: every node's idom is undefined except root
    idom = %{root => root}

    idom = iterate(graph, vertices, index, idom)
    idom
  end

  @doc """
  Computes the immediate post-dominator map.

  Reverses the CFG and computes dominators from the exit node.
  """
  @spec ipdom(Graph.t(), term()) :: %{term() => term()}
  def ipdom(graph, exit_node) do
    reversed = Graph.transpose(graph)
    idom(reversed, exit_node)
  end

  @doc """
  Builds a dominator tree from an immediate dominator map.

  Returns a `Graph.t()` where edges go from dominator to dominated.
  """
  @spec tree(map()) :: Graph.t()
  def tree(idom_map) do
    Enum.reduce(idom_map, Graph.new(), fn {node, dom}, g ->
      if node == dom do
        Graph.add_vertex(g, node)
      else
        g
        |> Graph.add_vertex(node)
        |> Graph.add_vertex(dom)
        |> Graph.add_edge(dom, node, label: :dominates)
      end
    end)
  end

  @doc """
  Computes the dominance frontier for each node.

  The dominance frontier of a node N is the set of nodes where
  N's dominance ends — where a node has a predecessor dominated by N
  but is not itself strictly dominated by N.
  """
  @spec frontier(Graph.t(), map()) :: %{term() => MapSet.t()}
  def frontier(cfg, idom_map) do
    nodes = Map.keys(idom_map)
    initial = Map.new(nodes, fn n -> {n, MapSet.new()} end)

    Enum.reduce(nodes, initial, fn node, df ->
      cfg
      |> predecessors(node)
      |> add_frontier_entries(node, idom_map, df)
    end)
  end

  @doc """
  Checks if `a` dominates `b` in the given idom map.
  """
  @spec dominates?(map(), term(), term()) :: boolean()
  def dominates?(_idom_map, a, a), do: true

  def dominates?(idom_map, a, b) do
    idom_b = Map.get(idom_map, b)

    if b == idom_b do
      false
    else
      dominates?(idom_map, a, idom_b)
    end
  end

  # --- Private ---

  defp iterate(graph, vertices, index, idom) do
    {new_idom, changed} =
      Enum.reduce(vertices, {idom, false}, fn node, {dom, changed} ->
        update_idom(graph, node, dom, changed, index)
      end)

    if changed do
      iterate(graph, vertices, index, new_idom)
    else
      new_idom
    end
  end

  defp update_idom(graph, node, dom, changed, index) do
    processed =
      graph
      |> predecessors(node)
      |> Enum.filter(&Map.has_key?(dom, &1))

    case processed do
      [] ->
        {dom, changed}

      [first | rest] ->
        new_idom =
          Enum.reduce(rest, first, fn pred, current ->
            intersect(pred, current, dom, index)
          end)

        if Map.get(dom, node) != new_idom do
          {Map.put(dom, node, new_idom), true}
        else
          {dom, changed}
        end
    end
  end

  defp intersect(b1, b2, idom, index) do
    intersect_loop(b1, b2, idom, index)
  end

  defp intersect_loop(f1, f2, _idom, _index) when f1 == f2, do: f1

  defp intersect_loop(f1, f2, idom, index) do
    i1 = Map.get(index, f1, -1)
    i2 = Map.get(index, f2, -1)

    if i1 > i2 do
      intersect_loop(Map.get(idom, f1, f1), f2, idom, index)
    else
      intersect_loop(f1, Map.get(idom, f2, f2), idom, index)
    end
  end

  defp add_frontier_entries(preds, _node, _idom_map, df) when length(preds) < 2, do: df

  defp add_frontier_entries(preds, node, idom_map, df) do
    Enum.reduce(preds, df, fn pred, df_acc ->
      walk_up(pred, node, idom_map, df_acc)
    end)
  end

  defp walk_up(runner, node, idom_map, df) do
    if runner == Map.get(idom_map, node) do
      df
    else
      df = Map.update!(df, runner, &MapSet.put(&1, node))
      next = Map.get(idom_map, runner, runner)

      if next == runner do
        df
      else
        walk_up(next, node, idom_map, df)
      end
    end
  end

  defp reverse_postorder(graph, root) do
    {_, order} = rpo_dfs(graph, root, MapSet.new(), [])
    order
  end

  defp rpo_dfs(graph, node, visited, acc) do
    if MapSet.member?(visited, node) do
      {visited, acc}
    else
      visited = MapSet.put(visited, node)

      succs = Graph.out_neighbors(graph, node)

      {visited, acc} =
        Enum.reduce(succs, {visited, acc}, fn succ, {v, a} ->
          rpo_dfs(graph, succ, v, a)
        end)

      {visited, [node | acc]}
    end
  end

  defp predecessors(graph, node) do
    Graph.in_neighbors(graph, node)
  end
end
