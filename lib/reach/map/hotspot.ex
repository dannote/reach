defmodule Reach.Map.Hotspot do
  @moduledoc false
  defstruct [
    :module,
    :function,
    :display_function,
    :file,
    :line,
    :branches,
    :callers,
    :score,
    :clauses
  ]

  def new(attrs), do: struct!(__MODULE__, attrs)
  def to_map(%__MODULE__{} = value), do: Reach.StructMap.compact(value)
end

defimpl Jason.Encoder, for: Reach.Map.Hotspot do
  def encode(value, opts), do: Jason.Encode.map(Reach.Map.Hotspot.to_map(value), opts)
end
