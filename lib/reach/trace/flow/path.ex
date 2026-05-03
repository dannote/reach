defmodule Reach.Trace.Flow.Path do
  @moduledoc false

  defstruct [:source, :sink, :intermediate]

  def new(attrs), do: struct!(__MODULE__, attrs)
  def to_map(%__MODULE__{} = path), do: Reach.StructMap.compact(path)
end

defimpl Jason.Encoder, for: Reach.Trace.Flow.Path do
  def encode(path, opts), do: Jason.Encode.map(Reach.Trace.Flow.Path.to_map(path), opts)
end
