defmodule Reach.Smell.Finding do
  @moduledoc "Struct for smell check findings with location and evidence."

  @enforce_keys [:kind, :message, :location]
  @derive Jason.Encoder
  defstruct [
    :kind,
    :message,
    :location,
    :evidence,
    :keys,
    :occurrences,
    :modules,
    :callbacks,
    :confidence
  ]

  def new(attrs) when is_list(attrs) or is_map(attrs) do
    struct!(__MODULE__, attrs)
  end
end
