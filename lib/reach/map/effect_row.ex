defmodule Reach.Map.EffectRow do
  @moduledoc "Struct for a per-function effect classification row."
  @derive Jason.Encoder
  defstruct [:effect, :count, :ratio]
  def new(attrs), do: struct!(__MODULE__, attrs)
end
