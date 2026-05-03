defmodule Reach.Inspect.Data.VariableSummary do
  @moduledoc false

  defstruct [:name, :role, :file, :line]

  def new(attrs), do: struct!(__MODULE__, attrs)
  def to_map(%__MODULE__{} = summary), do: Reach.StructMap.compact(summary)
end

defimpl Jason.Encoder, for: Reach.Inspect.Data.VariableSummary do
  def encode(summary, opts),
    do: Jason.Encode.map(Reach.Inspect.Data.VariableSummary.to_map(summary), opts)
end
