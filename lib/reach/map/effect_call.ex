defmodule Reach.Map.EffectCall do
  @moduledoc false
  defstruct [:effect, :call]
  def new(attrs), do: struct!(__MODULE__, attrs)
  def to_map(%__MODULE__{} = value), do: Reach.StructMap.compact(value)
end

defimpl Jason.Encoder, for: Reach.Map.EffectCall do
  def encode(value, opts), do: Jason.Encode.map(Reach.Map.EffectCall.to_map(value), opts)
end
