defmodule Reach.Map.DepthMetric do
  @moduledoc false
  defstruct [:module, :function, :depth, :clauses, :file, :line, :branch_count]
  def new(attrs), do: struct!(__MODULE__, attrs)
  def to_map(%__MODULE__{} = value), do: Reach.StructMap.compact(value)
end

defimpl Jason.Encoder, for: Reach.Map.DepthMetric do
  def encode(value, opts), do: Jason.Encode.map(Reach.Map.DepthMetric.to_map(value), opts)
end
