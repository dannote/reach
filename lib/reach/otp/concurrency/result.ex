defmodule Reach.OTP.Concurrency.Result do
  @moduledoc false

  @derive Jason.Encoder
  defstruct [:tasks, :monitors, :spawns, :supervisors, :concurrency_edges]

  def new(attrs), do: struct!(__MODULE__, attrs)
end
