defmodule Reach.Map.XrefEdge do
  @moduledoc false
  @derive Jason.Encoder
  defstruct [:from, :to, :edges, :labels, :variables]
  def new(attrs), do: struct!(__MODULE__, attrs)
end
