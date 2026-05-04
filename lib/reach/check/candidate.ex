defmodule Reach.Check.Candidate do
  @moduledoc false

  @derive Jason.Encoder
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
end
