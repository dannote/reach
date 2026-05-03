defmodule Reach.OTP.Analysis.StateTransform do
  @moduledoc false

  defstruct [:callback, :action, :location]

  def new(attrs), do: struct!(__MODULE__, attrs)
  def to_map(%__MODULE__{} = transform), do: Reach.StructMap.compact(transform)
end

defimpl Jason.Encoder, for: Reach.OTP.Analysis.StateTransform do
  def encode(transform, opts),
    do: Jason.Encode.map(Reach.OTP.Analysis.StateTransform.to_map(transform), opts)
end
