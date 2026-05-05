defmodule Reach.Check.DeadCode.Finding do
  @moduledoc false

  @derive Jason.Encoder
  defstruct [:file, :line, :kind, :description]

  def new(attrs), do: struct!(__MODULE__, attrs)
end
