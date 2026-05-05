defmodule Reach.OTP.Analysis.Supervisor do
  @moduledoc "Struct representing extracted supervisor child specifications."

  @derive Jason.Encoder
  defstruct [:module, :children, :location]

  def new(attrs), do: struct!(__MODULE__, attrs)
end
