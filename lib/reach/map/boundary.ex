defmodule Reach.Map.Boundary do
  @moduledoc "Struct for functions with multiple distinct side-effect kinds."
  @derive Jason.Encoder
  defstruct [:module, :function, :display_function, :file, :line, :effects, :calls]
  def new(attrs), do: struct!(__MODULE__, attrs)
end
