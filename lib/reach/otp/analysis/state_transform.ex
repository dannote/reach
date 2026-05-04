defmodule Reach.OTP.Analysis.StateTransform do
  @moduledoc false

  @derive Jason.Encoder
  defstruct [:callback, :action, :location]

  def new(attrs), do: struct!(__MODULE__, attrs)
end
