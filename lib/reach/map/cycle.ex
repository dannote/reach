defmodule Reach.Map.Cycle do
  @moduledoc "Struct for a module dependency cycle with its components."
  @derive Jason.Encoder
  defstruct [:modules]
  def new(attrs), do: struct!(__MODULE__, attrs)
end
