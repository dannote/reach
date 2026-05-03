defmodule Reach.Map.ModuleMetric do
  @moduledoc false
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
  def to_map(%__MODULE__{} = value), do: Reach.StructMap.compact(value)
end

defimpl Jason.Encoder, for: Reach.Map.ModuleMetric do
  def encode(value, opts), do: Jason.Encode.map(Reach.Map.ModuleMetric.to_map(value), opts)
end
