defmodule Reach.Inspect.Why.Result do
  @moduledoc false

  @derive Jason.Encoder
  defstruct [:command, :target, :why, :relation, :paths, :reason]

  def new(attrs), do: struct!(__MODULE__, attrs)
end
