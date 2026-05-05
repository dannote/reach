defmodule Reach.Inspect.Why.Path do
  @moduledoc "Struct for a single relationship path with evidence."

  @derive Jason.Encoder
  defstruct [:kind, :nodes, :evidence]

  def new(attrs), do: struct!(__MODULE__, attrs)
end
