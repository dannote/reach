defmodule Reach.Inspect.Data.Result do
  @moduledoc false

  @derive Jason.Encoder
  defstruct [:definitions, :uses, :returns, :edges]

  def new(attrs), do: struct!(__MODULE__, attrs)
end
