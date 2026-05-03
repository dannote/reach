defmodule Reach.Check.Changed.Function do
  @moduledoc false

  defstruct [
    :id,
    :file,
    :line,
    :risk,
    :risk_reasons,
    :public_api,
    :effects,
    :branch_count,
    :direct_callers,
    :direct_caller_count,
    :transitive_caller_count
  ]

  def new(attrs), do: struct!(__MODULE__, attrs)
  def to_map(%__MODULE__{} = function), do: Reach.StructMap.compact(function)
end

defimpl Jason.Encoder, for: Reach.Check.Changed.Function do
  def encode(function, opts),
    do: Jason.Encode.map(Reach.Check.Changed.Function.to_map(function), opts)
end
