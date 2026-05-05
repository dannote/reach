defmodule Reach.Map.DataSummary do
  @moduledoc "Struct for a cross-function data flow summary."
  @derive Jason.Encoder
  defstruct [:total_data_edges, :top_functions, :cross_function_edges]
  def new(attrs), do: struct!(__MODULE__, attrs)
end
