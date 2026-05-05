defmodule Reach.CloneAnalysis.Fragment do
  @moduledoc false

  @derive Jason.Encoder
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
end
