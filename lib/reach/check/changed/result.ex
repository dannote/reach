defmodule Reach.Check.Changed.Result do
  @moduledoc false

  @derive Jason.Encoder
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
end
