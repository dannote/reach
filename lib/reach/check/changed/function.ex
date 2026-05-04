defmodule Reach.Check.Changed.Function do
  @moduledoc false

  @derive Jason.Encoder
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
    :transitive_caller_count,
    clone_siblings: []
  ]

  def new(attrs), do: struct!(__MODULE__, attrs)
end
