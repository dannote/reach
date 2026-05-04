defmodule Reach.Trace.Flow.Result do
  @moduledoc false

  @derive Jason.Encoder
  defstruct [:type, :from, :to, :paths, :variable, :definitions, :uses]

  def new(attrs), do: struct!(__MODULE__, attrs)
end
