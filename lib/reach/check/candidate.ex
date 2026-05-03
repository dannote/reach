defmodule Reach.Check.Candidate do
  @moduledoc false

  defstruct [
    :id,
    :kind,
    :target,
    :file,
    :line,
    :benefit,
    :risk,
    :confidence,
    :actionability,
    :evidence,
    :effects,
    :proof,
    :suggestion,
    :modules,
    :representative_calls,
    :call,
    :branches,
    :direct_caller_count
  ]

  def new(attrs) when is_list(attrs) or is_map(attrs), do: struct!(__MODULE__, attrs)

  def to_map(%__MODULE__{} = candidate), do: Reach.StructMap.compact(candidate)
end

defimpl Jason.Encoder, for: Reach.Check.Candidate do
  def encode(candidate, opts), do: Jason.Encode.map(Reach.Check.Candidate.to_map(candidate), opts)
end
