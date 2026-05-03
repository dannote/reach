defmodule Reach.Inspect.Data.Result do
  @moduledoc false

  defstruct [:definitions, :uses, :returns, :edges]

  def new(attrs), do: struct!(__MODULE__, attrs)
  def to_map(%__MODULE__{} = result), do: Reach.StructMap.compact(result)
end

defimpl Jason.Encoder, for: Reach.Inspect.Data.Result do
  def encode(result, opts), do: Jason.Encode.map(Reach.Inspect.Data.Result.to_map(result), opts)
end
