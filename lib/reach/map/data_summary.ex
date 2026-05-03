defmodule Reach.Map.DataSummary do
  @moduledoc false
  defstruct [:total_data_edges, :top_functions, :cross_function_edges]
  def new(attrs), do: struct!(__MODULE__, attrs)
  def to_map(%__MODULE__{} = value), do: Reach.StructMap.compact(value)
end

defimpl Jason.Encoder, for: Reach.Map.DataSummary do
  def encode(value, opts), do: Jason.Encode.map(Reach.Map.DataSummary.to_map(value), opts)
end
