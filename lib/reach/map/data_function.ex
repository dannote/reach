defmodule Reach.Map.DataFunction do
  @moduledoc "Struct for a function with cross-function data flow edges."
  @derive Jason.Encoder
  defstruct [:function, :file, :line, :data_edges]
  def new(attrs), do: struct!(__MODULE__, attrs)
end
