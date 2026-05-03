defmodule Reach.StructMap do
  @moduledoc false

  def compact(struct) do
    struct
    |> Map.from_struct()
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end
end
