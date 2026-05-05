defmodule Reach.Trace.Flow.Path do
  @moduledoc "Struct for a single taint flow path."

  @derive Jason.Encoder
  defstruct [:source, :sink, :intermediate]

  def new(attrs), do: struct!(__MODULE__, attrs)
end
