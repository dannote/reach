defmodule Reach.Map.EffectRow do
  @moduledoc false
  defstruct [:effect, :count, :ratio]
  def new(attrs), do: struct!(__MODULE__, attrs)
  def to_map(%__MODULE__{} = value), do: Reach.StructMap.compact(value)
end

defimpl Jason.Encoder, for: Reach.Map.EffectRow do
  def encode(value, opts), do: Jason.Encode.map(Reach.Map.EffectRow.to_map(value), opts)
end
