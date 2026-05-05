defmodule Reach.Map.ModuleCoupling do
  @moduledoc false
  @derive Jason.Encoder
  defstruct [:name, :file, :afferent, :efferent, :instability]
  def new(attrs), do: struct!(__MODULE__, attrs)
end
