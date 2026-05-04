defmodule Reach.Trace.Slice.Statement do
  @moduledoc false

  @derive Jason.Encoder
  defstruct [:file, :line, :description, :type]

  def new(attrs), do: struct!(__MODULE__, attrs)
end
