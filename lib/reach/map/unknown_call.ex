defmodule Reach.Map.UnknownCall do
  @moduledoc false
  @derive Jason.Encoder
  defstruct [:module, :function, :count]
  def new(attrs), do: struct!(__MODULE__, attrs)
end
