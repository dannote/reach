defmodule Reach.Map.DepthMetric do
  @moduledoc false
  @derive Jason.Encoder
  defstruct [:module, :function, :depth, :clauses, :file, :line, :branch_count]
  def new(attrs), do: struct!(__MODULE__, attrs)
end
