defmodule Reach.Inspect.Why.Result do
  @moduledoc false

  defstruct [:command, :target, :why, :relation, :paths, :reason]

  def new(attrs), do: struct!(__MODULE__, attrs)
  def to_map(%__MODULE__{} = result), do: Reach.StructMap.compact(result)
end

defimpl Jason.Encoder, for: Reach.Inspect.Why.Result do
  def encode(result, opts), do: Jason.Encode.map(Reach.Inspect.Why.Result.to_map(result), opts)
end
