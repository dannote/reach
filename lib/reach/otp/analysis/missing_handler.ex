defmodule Reach.OTP.Analysis.MissingHandler do
  @moduledoc false

  @derive Jason.Encoder
  defstruct [:location, :message]

  def new(attrs), do: struct!(__MODULE__, attrs)
end
