defmodule Reach.Map.UnknownCall do
  @moduledoc false
  defstruct [:module, :function, :count]
  def new(attrs), do: struct!(__MODULE__, attrs)
  def to_map(%__MODULE__{} = value), do: Reach.StructMap.compact(value)
end

defimpl Jason.Encoder, for: Reach.Map.UnknownCall do
  def encode(value, opts), do: Jason.Encode.map(Reach.Map.UnknownCall.to_map(value), opts)
end
