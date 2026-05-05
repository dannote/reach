defmodule Reach.Trace.Slice.Result do
  @moduledoc "Struct for program slice results."

  @derive Jason.Encoder
  defstruct [:node, :direction, :statements]

  def new(attrs), do: struct!(__MODULE__, attrs)
end
