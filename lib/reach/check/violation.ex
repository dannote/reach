defmodule Reach.Check.Violation do
  @moduledoc false

  defstruct [
    :type,
    :caller_module,
    :caller_layer,
    :callee_module,
    :callee_layer,
    :file,
    :line,
    :call,
    :layers,
    :module,
    :function,
    :allowed_effects,
    :actual_effects,
    :disallowed_effects,
    :rule,
    :key,
    :path,
    :message
  ]

  def new(attrs) when is_list(attrs) or is_map(attrs), do: struct!(__MODULE__, attrs)

  def to_map(%__MODULE__{} = violation), do: Reach.StructMap.compact(violation)
end

defimpl Jason.Encoder, for: Reach.Check.Violation do
  def encode(violation, opts), do: Jason.Encode.map(Reach.Check.Violation.to_map(violation), opts)
end
