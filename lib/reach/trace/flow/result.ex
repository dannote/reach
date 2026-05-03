defmodule Reach.Trace.Flow.Result do
  @moduledoc false

  defstruct [:type, :from, :to, :paths, :variable, :definitions, :uses]

  def new(attrs), do: struct!(__MODULE__, attrs)
  def to_map(%__MODULE__{} = result), do: Reach.StructMap.compact(result)
end

defimpl Jason.Encoder, for: Reach.Trace.Flow.Result do
  def encode(result, opts), do: Jason.Encode.map(Reach.Trace.Flow.Result.to_map(result), opts)
end
