defmodule Reach.Map.Cycle do
  @moduledoc false
  @derive Jason.Encoder
  defstruct [:modules]
  def new(attrs), do: struct!(__MODULE__, attrs)
end
