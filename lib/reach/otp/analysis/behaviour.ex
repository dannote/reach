defmodule Reach.OTP.Analysis.Behaviour do
  @moduledoc false

  defstruct [:module, :behaviour, :callbacks, :state_transforms]

  def new(attrs), do: struct!(__MODULE__, attrs)
  def to_map(%__MODULE__{} = behaviour), do: Reach.StructMap.compact(behaviour)
end

defimpl Jason.Encoder, for: Reach.OTP.Analysis.Behaviour do
  def encode(behaviour, opts),
    do: Jason.Encode.map(Reach.OTP.Analysis.Behaviour.to_map(behaviour), opts)
end
