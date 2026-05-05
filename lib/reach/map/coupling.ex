defmodule Reach.Map.Coupling do
  @moduledoc "Struct for module coupling metrics including afferent, efferent, and instability."
  @derive Jason.Encoder
  defstruct [:modules, :cycles]
  def new(attrs), do: struct!(__MODULE__, attrs)
end
