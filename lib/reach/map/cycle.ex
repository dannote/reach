defmodule Reach.Map.Cycle do
  @moduledoc false
  defstruct [:modules]
  def new(attrs), do: struct!(__MODULE__, attrs)
  def to_map(%__MODULE__{} = value), do: Reach.StructMap.compact(value)
end

defimpl Jason.Encoder, for: Reach.Map.Cycle do
  def encode(value, opts), do: Jason.Encode.map(Reach.Map.Cycle.to_map(value), opts)
end
