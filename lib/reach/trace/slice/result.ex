defmodule Reach.Trace.Slice.Result do
  @moduledoc false

  @derive Jason.Encoder
  defstruct [:node, :direction, :statements]

  def new(attrs), do: struct!(__MODULE__, attrs)
end
