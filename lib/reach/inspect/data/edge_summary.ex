defmodule Reach.Inspect.Data.EdgeSummary do
  @moduledoc false

  @derive Jason.Encoder
  defstruct [:from, :to, :label]

  def new(attrs), do: struct!(__MODULE__, attrs)
end
