defmodule ExPDG.GraphUtils do
  @moduledoc false

  @doc """
  Merges two `Graph.t()` structs, combining all vertices and edges.
  """
  @spec merge(Graph.t(), Graph.t()) :: Graph.t()
  def merge(g1, g2) do
    graph =
      g1
      |> Graph.vertices()
      |> Enum.reduce(Graph.new(), &Graph.add_vertex(&2, &1))

    graph =
      g1
      |> Graph.edges()
      |> Enum.reduce(graph, fn e, g ->
        Graph.add_edge(g, e.v1, e.v2, label: e.label)
      end)

    graph =
      g2
      |> Graph.vertices()
      |> Enum.reduce(graph, &Graph.add_vertex(&2, &1))

    g2
    |> Graph.edges()
    |> Enum.reduce(graph, fn e, g ->
      Graph.add_edge(g, e.v1, e.v2, label: e.label)
    end)
  end
end
