defmodule Reach.ControlDependence do
  @moduledoc false

  alias Reach.Dominator

  @doc """
  Builds a control dependence graph from a control flow graph.

  The control flow graph must have `:entry` and `:exit` vertices.
  Returns a `Graph.t()` where edges represent control dependence
  with labels indicating the branch condition.
  """
  @spec build(Graph.t()) :: Graph.t()
  def build(cfg) do
    ipdom = Dominator.ipdom(cfg, :exit)
    cdg = Graph.new()

    # Add all CFG vertices to the CDG
    cdg =
      Graph.vertices(cfg)
      |> Enum.reduce(cdg, &Graph.add_vertex(&2, &1))

    # For each CFG edge (a, b), if b does not post-dominate a,
    # mark nodes as control-dependent on a
    Graph.edges(cfg)
    |> Enum.reduce(cdg, fn edge, cdg_acc ->
      a = edge.v1
      b = edge.v2
      edge_label = edge.label

      if Dominator.dominates?(ipdom, b, a) do
        cdg_acc
      else
        # Ferrante et al.: walk up post-dominator tree from B,
        # stopping at ipdom(A) exclusive. Mark each visited node
        # as control-dependent on A.
        target = Map.get(ipdom, a, a)
        add_control_deps(cdg_acc, a, b, target, ipdom, edge_label)
      end
    end)
  end

  # Walk up the post-dominator tree from `runner` to `target`,
  # adding control dependence edges from `source` to each visited node.
  defp add_control_deps(cdg, source, runner, target, ipdom, label) do
    if runner == target do
      cdg
    else
      cdg = Graph.add_edge(cdg, source, runner, label: {:control, label})
      next = Map.get(ipdom, runner, runner)

      if next == runner do
        cdg
      else
        add_control_deps(cdg, source, next, target, ipdom, label)
      end
    end
  end
end
