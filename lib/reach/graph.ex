defmodule Reach.Graph do
  @moduledoc "Adjacency-list graph data structure with vertex and edge operations."

  @doc """
  Merges multiple `Graph.t()` structs by combining their internal maps.

  Much faster than `Graph.add_edges/2` in a loop because it avoids
  per-edge vertex ID hashing and map lookups.
  """
  @spec merge([Graph.t()]) :: Graph.t()
  def merge(graphs) do
    Enum.reduce(graphs, Graph.new(), fn g, %Graph{} = acc ->
      %Graph{
        acc
        | vertices: Map.merge(acc.vertices, g.vertices),
          edges: Map.merge(acc.edges, g.edges, fn _k, v1, v2 -> Map.merge(v1, v2) end),
          out_edges:
            Map.merge(acc.out_edges, g.out_edges, fn _k, v1, v2 ->
              MapSet.union(v1, v2)
            end),
          in_edges:
            Map.merge(acc.in_edges, g.in_edges, fn _k, v1, v2 ->
              MapSet.union(v1, v2)
            end),
          vertex_labels: Map.merge(acc.vertex_labels, g.vertex_labels)
      }
    end)
  end
end
