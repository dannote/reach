defmodule Reach.Map.Coupling do
  @moduledoc false
  defstruct [:modules, :cycles]
  def new(attrs), do: struct!(__MODULE__, attrs)
  def to_map(%__MODULE__{} = value), do: Reach.StructMap.compact(value)
end

defimpl Jason.Encoder, for: Reach.Map.Coupling do
  def encode(value, opts), do: Jason.Encode.map(Reach.Map.Coupling.to_map(value), opts)
end
