defmodule Reach.IR.Counter do
  @moduledoc false

  @opaque t :: :atomics.atomics_ref()

  @spec new() :: t()
  def new do
    :atomics.new(1, signed: true)
  end

  @spec next(t()) :: non_neg_integer()
  def next(ref) do
    :atomics.add_get(ref, 1, 1) - 1
  end
end
