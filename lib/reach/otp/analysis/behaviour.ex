defmodule Reach.OTP.Analysis.Behaviour do
  @moduledoc "Struct representing a detected OTP behaviour with its callbacks and state transforms."

  @derive Jason.Encoder
  defstruct [:module, :behaviour, :callbacks, :state_transforms]

  def new(attrs), do: struct!(__MODULE__, attrs)
end
