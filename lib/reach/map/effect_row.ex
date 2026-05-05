defmodule Reach.Map.EffectRow do
  @moduledoc false
  @derive Jason.Encoder
  defstruct [:effect, :count, :ratio]
  def new(attrs), do: struct!(__MODULE__, attrs)
end
