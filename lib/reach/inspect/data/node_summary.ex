defmodule Reach.Inspect.Data.NodeSummary do
  @moduledoc false

  @derive Jason.Encoder
  defstruct [:id, :kind, :name, :file, :line]

  def new(attrs), do: struct!(__MODULE__, attrs)
end
