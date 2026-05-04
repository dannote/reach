defmodule Reach.OTP.Analysis.Behaviour do
  @moduledoc false

  @derive Jason.Encoder
  defstruct [:module, :behaviour, :callbacks, :state_transforms]

  def new(attrs), do: struct!(__MODULE__, attrs)
end
