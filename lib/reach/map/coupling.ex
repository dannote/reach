defmodule Reach.Map.Coupling do
  @moduledoc false
  @derive Jason.Encoder
  defstruct [:modules, :cycles]
  def new(attrs), do: struct!(__MODULE__, attrs)
end
