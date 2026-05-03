defmodule Reach.CloneAnalysis.Fragment do
  @moduledoc false

  defstruct [
    :file,
    :line,
    :module,
    :function,
    :arity,
    :effects,
    :effect_sequence,
    :calls,
    :return_shapes,
    :map_accesses,
    :validation_calls,
    :mass
  ]

  def new(attrs), do: struct!(__MODULE__, attrs)
  def to_map(%__MODULE__{} = fragment), do: Reach.StructMap.compact(fragment)
end

defimpl Jason.Encoder, for: Reach.CloneAnalysis.Fragment do
  def encode(fragment, opts),
    do: Jason.Encode.map(Reach.CloneAnalysis.Fragment.to_map(fragment), opts)
end
