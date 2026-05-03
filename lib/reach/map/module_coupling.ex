defmodule Reach.Map.ModuleCoupling do
  @moduledoc false
  defstruct [:name, :file, :afferent, :efferent, :instability]
  def new(attrs), do: struct!(__MODULE__, attrs)
  def to_map(%__MODULE__{} = value), do: Reach.StructMap.compact(value)
end

defimpl Jason.Encoder, for: Reach.Map.ModuleCoupling do
  def encode(value, opts), do: Jason.Encode.map(Reach.Map.ModuleCoupling.to_map(value), opts)
end
