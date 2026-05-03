defmodule Reach.OTP.Concurrency.Result do
  @moduledoc false

  defstruct [:tasks, :monitors, :spawns, :supervisors, :concurrency_edges]

  def new(attrs), do: struct!(__MODULE__, attrs)
  def to_map(%__MODULE__{} = result), do: Reach.StructMap.compact(result)
end

defimpl Jason.Encoder, for: Reach.OTP.Concurrency.Result do
  def encode(result, opts),
    do: Jason.Encode.map(Reach.OTP.Concurrency.Result.to_map(result), opts)
end
