defmodule Reach.Inspect.Why.Path do
  @moduledoc false

  defstruct [:kind, :nodes, :evidence]

  def new(attrs), do: struct!(__MODULE__, attrs)
  def to_map(%__MODULE__{} = path), do: Reach.StructMap.compact(path)
end

defimpl Jason.Encoder, for: Reach.Inspect.Why.Path do
  def encode(path, opts), do: Jason.Encode.map(Reach.Inspect.Why.Path.to_map(path), opts)
end
