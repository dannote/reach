defmodule Reach.Smell.Finding do
  @moduledoc false

  @enforce_keys [:kind, :message, :location]
  defstruct [:kind, :message, :location, :evidence, :keys, :occurrences]

  def new(attrs) when is_list(attrs) or is_map(attrs) do
    struct!(__MODULE__, attrs)
  end

  def to_map(%__MODULE__{} = finding) do
    finding
    |> Map.from_struct()
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end
end
