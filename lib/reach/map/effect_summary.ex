defmodule Reach.Map.EffectSummary do
  @moduledoc false
  @derive Jason.Encoder
  defstruct [:total_calls, :distribution, :unknown_calls]
  def new(attrs), do: struct!(__MODULE__, attrs)
end
