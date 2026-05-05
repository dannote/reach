defmodule Reach.Map.Summary do
  @moduledoc false
  @derive Jason.Encoder
  defstruct [
    :modules,
    :functions,
    :call_graph_vertices,
    :call_graph_edges,
    :graph_nodes,
    :graph_edges,
    :effects
  ]

  def new(attrs), do: struct!(__MODULE__, attrs)
end
