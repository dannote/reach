defmodule Reach.IR.Node do
  @moduledoc """
  A node in the internal representation.

  Every node is an expression or sub-expression, following the expression-oriented
  approach (EDG) rather than statement-oriented (classic PDG).
  """

  @type id :: non_neg_integer()

  @type node_type ::
          :entry
          | :exit
          | :block
          | :literal
          | :var
          | :match
          | :call
          | :case
          | :clause
          | :guard
          | :fn
          | :try
          | :rescue
          | :catch_clause
          | :after
          | :receive
          | :comprehension
          | :generator
          | :filter
          | :binary_op
          | :unary_op
          | :tuple
          | :list
          | :cons
          | :map
          | :map_field
          | :struct
          | :pin
          | :access
          | :module_def
          | :function_def
          | :dispatch

  @type source_span :: %{
          file: String.t() | nil,
          start_line: pos_integer(),
          start_col: pos_integer(),
          end_line: pos_integer() | nil,
          end_col: pos_integer() | nil
        }

  @type t :: %__MODULE__{
          id: id(),
          type: node_type(),
          meta: map(),
          children: [t()],
          source_span: source_span() | nil
        }

  @enforce_keys [:id, :type]
  defstruct [
    :id,
    :type,
    meta: %{},
    children: [],
    source_span: nil
  ]
end
