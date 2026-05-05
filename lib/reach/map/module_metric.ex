defmodule Reach.Map.ModuleMetric do
  @moduledoc "Struct for per-module complexity metrics."
  @derive Jason.Encoder
  defstruct [
    :name,
    :file,
    :functions,
    :public,
    :private,
    :complexity,
    :public_count,
    :private_count,
    :macro_count,
    :total_functions,
    :total_complexity,
    :biggest_function,
    :callbacks,
    :fan_in,
    :fan_out
  ]

  def new(attrs), do: struct!(__MODULE__, attrs)
end
