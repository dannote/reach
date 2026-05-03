defmodule Reach.Map.EffectSummary do
  @moduledoc false
  defstruct [:total_calls, :distribution, :unknown_calls]
  def new(attrs), do: struct!(__MODULE__, attrs)
  def to_map(%__MODULE__{} = value), do: Reach.StructMap.compact(value)
end

defimpl Jason.Encoder, for: Reach.Map.EffectSummary do
  def encode(value, opts), do: Jason.Encode.map(Reach.Map.EffectSummary.to_map(value), opts)
end
