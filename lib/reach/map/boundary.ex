defmodule Reach.Map.Boundary do
  @moduledoc false
  defstruct [:module, :function, :display_function, :file, :line, :effects, :calls]
  def new(attrs), do: struct!(__MODULE__, attrs)
  def to_map(%__MODULE__{} = value), do: Reach.StructMap.compact(value)
end

defimpl Jason.Encoder, for: Reach.Map.Boundary do
  def encode(value, opts), do: Jason.Encode.map(Reach.Map.Boundary.to_map(value), opts)
end
