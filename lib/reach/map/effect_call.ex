defmodule Reach.Map.EffectCall do
  @moduledoc "Struct for a call site with its classified effect."
  @derive Jason.Encoder
  defstruct [:effect, :call]
  def new(attrs), do: struct!(__MODULE__, attrs)
end
