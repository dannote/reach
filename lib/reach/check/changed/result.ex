defmodule Reach.Check.Changed.Result do
  @moduledoc false

  defstruct [
    :base,
    :risk,
    :risk_reasons,
    :changed_files,
    :changed_functions,
    :public_api_changes,
    :suggested_tests
  ]

  def new(attrs), do: struct!(__MODULE__, attrs)
  def to_map(%__MODULE__{} = result), do: Reach.StructMap.compact(result)
end

defimpl Jason.Encoder, for: Reach.Check.Changed.Result do
  def encode(result, opts), do: Jason.Encode.map(Reach.Check.Changed.Result.to_map(result), opts)
end
