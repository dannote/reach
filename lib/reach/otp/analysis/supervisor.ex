defmodule Reach.OTP.Analysis.Supervisor do
  @moduledoc false

  @derive Jason.Encoder
  defstruct [:module, :children, :location]

  def new(attrs), do: struct!(__MODULE__, attrs)
end
