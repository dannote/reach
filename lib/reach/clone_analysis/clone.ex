defmodule Reach.CloneAnalysis.Clone do
  @moduledoc false

  defstruct [:type, :mass, :similarity, :fragments, :suggestion]

  def new(attrs), do: struct!(__MODULE__, attrs)
  def to_map(%__MODULE__{} = clone), do: Reach.StructMap.compact(clone)
end

defimpl Jason.Encoder, for: Reach.CloneAnalysis.Clone do
  def encode(clone, opts), do: Jason.Encode.map(Reach.CloneAnalysis.Clone.to_map(clone), opts)
end
