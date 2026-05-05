defmodule Reach.OTP.Analysis.StateTransform do
  @moduledoc "Struct representing a state transformation performed within an OTP callback."

  @derive Jason.Encoder
  defstruct [:callback, :action, :location]

  def new(attrs), do: struct!(__MODULE__, attrs)
end
