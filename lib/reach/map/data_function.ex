defmodule Reach.Map.DataFunction do
  @moduledoc false
  defstruct [:function, :file, :line, :data_edges]
  def new(attrs), do: struct!(__MODULE__, attrs)
  def to_map(%__MODULE__{} = value), do: Reach.StructMap.compact(value)
end

defimpl Jason.Encoder, for: Reach.Map.DataFunction do
  def encode(value, opts), do: Jason.Encode.map(Reach.Map.DataFunction.to_map(value), opts)
end
