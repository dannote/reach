defmodule Reach.OTP.Analysis.Result do
  @moduledoc false

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
  def to_map(%__MODULE__{} = result), do: Reach.StructMap.compact(result)
end

defimpl Jason.Encoder, for: Reach.OTP.Analysis.Result do
  def encode(result, opts), do: Jason.Encode.map(Reach.OTP.Analysis.Result.to_map(result), opts)
end
