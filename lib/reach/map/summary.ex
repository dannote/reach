defmodule Reach.Map.Summary do
  @moduledoc false
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
  def to_map(%__MODULE__{} = value), do: Reach.StructMap.compact(value)
end

defimpl Jason.Encoder, for: Reach.Map.Summary do
  def encode(value, opts), do: Jason.Encode.map(Reach.Map.Summary.to_map(value), opts)
end
