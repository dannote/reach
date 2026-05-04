defmodule Reach.Map.Boundary do
  @moduledoc false
  @derive Jason.Encoder
  defstruct [:module, :function, :display_function, :file, :line, :effects, :calls]
  def new(attrs), do: struct!(__MODULE__, attrs)
end
