defmodule Reach.Trace.Flow.Path do
  @moduledoc false

  @derive Jason.Encoder
  defstruct [:source, :sink, :intermediate]

  def new(attrs), do: struct!(__MODULE__, attrs)
end
