defmodule Reach.Trace.Slice.Statement do
  @moduledoc false

  defstruct [:file, :line, :description, :type]

  def new(attrs), do: struct!(__MODULE__, attrs)
  def to_map(%__MODULE__{} = statement), do: Reach.StructMap.compact(statement)
end

defimpl Jason.Encoder, for: Reach.Trace.Slice.Statement do
  def encode(statement, opts),
    do: Jason.Encode.map(Reach.Trace.Slice.Statement.to_map(statement), opts)
end
