defmodule Reach.GraphUtils do
  @moduledoc false

  @doc """
  Merges two `Graph.t()` structs, combining all vertices and edges.
  """
  @spec merge(Graph.t(), Graph.t()) :: Graph.t()
  def merge(g1, g2) do
    Graph.new()
    |> Graph.add_edges(Graph.edges(g1))
    |> Graph.add_edges(Graph.edges(g2))
  end
end
