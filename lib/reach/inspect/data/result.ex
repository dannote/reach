defmodule Reach.Inspect.Data.Result do
  @moduledoc "Struct for data inspection results."

  @derive Jason.Encoder
  defstruct [:definitions, :uses, :returns, :edges]

  def new(attrs), do: struct!(__MODULE__, attrs)
end
