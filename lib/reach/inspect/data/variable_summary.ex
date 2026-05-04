defmodule Reach.Inspect.Data.VariableSummary do
  @moduledoc false

  @derive Jason.Encoder
  defstruct [:name, :role, :file, :line]

  def new(attrs), do: struct!(__MODULE__, attrs)
end
