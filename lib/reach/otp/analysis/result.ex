defmodule Reach.OTP.Analysis.Result do
  @moduledoc false

  @derive Jason.Encoder
  defstruct [
    :behaviours,
    :state_machines,
    :hidden_coupling,
    :missing_handlers,
    :supervision,
    :dead_replies,
    :cross_process
  ]

  def new(attrs), do: struct!(__MODULE__, attrs)
end
