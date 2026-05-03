defmodule Reach.OTP.Analysis.Supervisor do
  @moduledoc false

  defstruct [:module, :children, :location]

  def new(attrs), do: struct!(__MODULE__, attrs)
  def to_map(%__MODULE__{} = supervisor), do: Reach.StructMap.compact(supervisor)
end

defimpl Jason.Encoder, for: Reach.OTP.Analysis.Supervisor do
  def encode(supervisor, opts),
    do: Jason.Encode.map(Reach.OTP.Analysis.Supervisor.to_map(supervisor), opts)
end
