defmodule Reach.Inspect.Data.NodeSummary do
  @moduledoc false

  defstruct [:id, :kind, :name, :file, :line]

  def new(attrs), do: struct!(__MODULE__, attrs)
  def to_map(%__MODULE__{} = summary), do: Reach.StructMap.compact(summary)
end

defimpl Jason.Encoder, for: Reach.Inspect.Data.NodeSummary do
  def encode(summary, opts),
    do: Jason.Encode.map(Reach.Inspect.Data.NodeSummary.to_map(summary), opts)
end
