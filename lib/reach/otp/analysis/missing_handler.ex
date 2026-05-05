defmodule Reach.OTP.Analysis.MissingHandler do
  @moduledoc "Struct representing a missing GenServer or gen_statem handler finding."

  @derive Jason.Encoder
  defstruct [:location, :message]

  def new(attrs), do: struct!(__MODULE__, attrs)
end
