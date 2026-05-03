defmodule Reach.Check.DeadCode.Finding do
  @moduledoc false

  defstruct [:file, :line, :kind, :description]

  def new(attrs), do: struct!(__MODULE__, attrs)
  def to_map(%__MODULE__{} = finding), do: Reach.StructMap.compact(finding)
end

defimpl Jason.Encoder, for: Reach.Check.DeadCode.Finding do
  def encode(finding, opts),
    do: Jason.Encode.map(Reach.Check.DeadCode.Finding.to_map(finding), opts)
end
