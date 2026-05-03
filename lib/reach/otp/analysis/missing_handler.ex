defmodule Reach.OTP.Analysis.MissingHandler do
  @moduledoc false

  defstruct [:location, :message]

  def new(attrs), do: struct!(__MODULE__, attrs)
  def to_map(%__MODULE__{} = handler), do: Reach.StructMap.compact(handler)
end

defimpl Jason.Encoder, for: Reach.OTP.Analysis.MissingHandler do
  def encode(handler, opts),
    do: Jason.Encode.map(Reach.OTP.Analysis.MissingHandler.to_map(handler), opts)
end
