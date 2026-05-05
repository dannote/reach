defmodule Reach.CloneAnalysis.Clone do
  @moduledoc false

  @derive Jason.Encoder
  defstruct [:type, :mass, :similarity, :fragments, :suggestion]

  def new(attrs), do: struct!(__MODULE__, attrs)
end
