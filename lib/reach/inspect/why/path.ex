defmodule Reach.Inspect.Why.Path do
  @moduledoc false

  @derive Jason.Encoder
  defstruct [:kind, :nodes, :evidence]

  def new(attrs), do: struct!(__MODULE__, attrs)
end
