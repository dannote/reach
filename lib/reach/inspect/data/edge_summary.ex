defmodule Reach.Inspect.Data.EdgeSummary do
  @moduledoc false

  defstruct [:from, :to, :label]

  def new(attrs), do: struct!(__MODULE__, attrs)
  def to_map(%__MODULE__{} = summary), do: Reach.StructMap.compact(summary)
end

defimpl Jason.Encoder, for: Reach.Inspect.Data.EdgeSummary do
  def encode(summary, opts),
    do: Jason.Encode.map(Reach.Inspect.Data.EdgeSummary.to_map(summary), opts)
end
