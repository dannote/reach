defmodule Reach.Map.XrefEdge do
  @moduledoc false
  defstruct [:from, :to, :edges, :labels, :variables]
  def new(attrs), do: struct!(__MODULE__, attrs)
  def to_map(%__MODULE__{} = value), do: Reach.StructMap.compact(value)
end

defimpl Jason.Encoder, for: Reach.Map.XrefEdge do
  def encode(value, opts), do: Jason.Encode.map(Reach.Map.XrefEdge.to_map(value), opts)
end
