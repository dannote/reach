defmodule Reach.Map.DataFunction do
  @moduledoc false
  @derive Jason.Encoder
  defstruct [:function, :file, :line, :data_edges]
  def new(attrs), do: struct!(__MODULE__, attrs)
end
