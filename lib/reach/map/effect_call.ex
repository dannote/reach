defmodule Reach.Map.EffectCall do
  @moduledoc false
  @derive Jason.Encoder
  defstruct [:effect, :call]
  def new(attrs), do: struct!(__MODULE__, attrs)
end
