defmodule Reach.Trace.Slice.Statement do
  @moduledoc "Struct for a single statement in a program slice."

  @derive Jason.Encoder
  defstruct [:file, :line, :description, :type]

  def new(attrs), do: struct!(__MODULE__, attrs)
end
