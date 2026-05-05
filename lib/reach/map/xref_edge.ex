defmodule Reach.Map.XrefEdge do
  @moduledoc "Struct for a cross-function reference edge."
  @derive Jason.Encoder
  defstruct [:from, :to, :edges, :labels, :variables]
  def new(attrs), do: struct!(__MODULE__, attrs)
end
