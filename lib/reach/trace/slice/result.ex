defmodule Reach.Trace.Slice.Result do
  @moduledoc false

  defstruct [:node, :direction, :statements]

  def new(attrs), do: struct!(__MODULE__, attrs)
  def to_map(%__MODULE__{} = result), do: Reach.StructMap.compact(result)
end

defimpl Jason.Encoder, for: Reach.Trace.Slice.Result do
  def encode(result, opts), do: Jason.Encode.map(Reach.Trace.Slice.Result.to_map(result), opts)
end
