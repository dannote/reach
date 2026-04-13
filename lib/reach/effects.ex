defmodule Reach.Effects do
  @moduledoc """
  Effect classification for IR nodes.

  Classifies each expression by its side effects — pure computations,
  IO, mutable state access, message passing, etc. Used by independence
  queries to determine whether reordering is safe.
  """

  alias Reach.IR.Node

  @type effect ::
          :pure
          | :read
          | :write
          | :io
          | :send
          | :receive
          | :exception
          | :nif
          | :unknown

  @doc """
  Classifies the effect of an IR node.
  """
  @spec classify(Node.t()) :: effect()
  def classify(%Node{type: :literal}), do: :pure
  def classify(%Node{type: :var}), do: :pure
  def classify(%Node{type: :pin}), do: :pure
  def classify(%Node{type: :tuple}), do: :pure
  def classify(%Node{type: :list}), do: :pure
  def classify(%Node{type: :cons}), do: :pure
  def classify(%Node{type: :map}), do: :pure
  def classify(%Node{type: :map_field}), do: :pure
  def classify(%Node{type: :struct}), do: :pure
  def classify(%Node{type: :match}), do: :pure
  def classify(%Node{type: :block}), do: :pure
  def classify(%Node{type: :guard}), do: :pure
  def classify(%Node{type: :clause}), do: :pure
  def classify(%Node{type: :entry}), do: :pure
  def classify(%Node{type: :exit}), do: :pure

  def classify(%Node{type: :binary_op}), do: :pure
  def classify(%Node{type: :unary_op}), do: :pure

  def classify(%Node{type: :receive}), do: :receive

  def classify(%Node{type: :call} = node) do
    classify_call(node.meta[:module], node.meta[:function], node.meta[:arity])
  end

  def classify(_node), do: :unknown

  @doc """
  Returns true if the node is pure (no side effects).
  """
  @spec pure?(Node.t()) :: boolean()
  def pure?(node), do: classify(node) == :pure

  @doc """
  Returns true if the node has the given effect.
  """
  @spec effectful?(Node.t(), effect()) :: boolean()
  def effectful?(node, effect), do: classify(node) == effect

  @doc """
  Returns true if two effects conflict (reordering may change behavior).
  """
  @spec conflicting?(effect(), effect()) :: boolean()
  def conflicting?(:pure, _), do: false
  def conflicting?(_, :pure), do: false
  def conflicting?(:unknown, _), do: true
  def conflicting?(_, :unknown), do: true
  def conflicting?(:write, :write), do: true
  def conflicting?(:write, :read), do: true
  def conflicting?(:read, :write), do: true
  def conflicting?(:io, :io), do: true
  def conflicting?(:send, :send), do: true
  def conflicting?(:send, :receive), do: true
  def conflicting?(:receive, :send), do: true
  def conflicting?(:receive, :receive), do: true
  def conflicting?(_, _), do: false

  # --- Pure function database ---

  @pure_modules [
    Enum,
    Stream,
    Map,
    Keyword,
    List,
    Tuple,
    String,
    Atom,
    Integer,
    Float,
    MapSet,
    Range,
    Regex,
    URI,
    Path,
    Base,
    Bitwise,
    Macro,
    Version,
    :lists,
    :maps,
    :ordsets,
    :orddict,
    :sets,
    :gb_sets,
    :gb_trees,
    :dict,
    :proplists,
    :string,
    :binary,
    :math,
    :unicode,
    :filename,
    :re
  ]

  @pure_kernel_functions [
    :+,
    :-,
    :*,
    :/,
    :==,
    :!=,
    :===,
    :!==,
    :<,
    :>,
    :<=,
    :>=,
    :and,
    :or,
    :not,
    :!,
    :in,
    :..,
    :<>,
    :abs,
    :ceil,
    :floor,
    :round,
    :trunc,
    :div,
    :rem,
    :max,
    :min,
    :hd,
    :tl,
    :length,
    :elem,
    :tuple_size,
    :map_size,
    :is_atom,
    :is_binary,
    :is_bitstring,
    :is_boolean,
    :is_float,
    :is_function,
    :is_integer,
    :is_list,
    :is_map,
    :is_nil,
    :is_number,
    :is_pid,
    :is_port,
    :is_reference,
    :is_tuple,
    :is_map_key,
    :node,
    :self,
    :binary_part,
    :bit_size,
    :byte_size,
    :is_exception,
    :is_struct,
    :to_string,
    :to_charlist,
    :inspect
  ]

  @pure_erlang_functions [
    {:erlang, :abs, 1},
    {:erlang, :element, 2},
    {:erlang, :hd, 1},
    {:erlang, :length, 1},
    {:erlang, :map_size, 1},
    {:erlang, :max, 2},
    {:erlang, :min, 2},
    {:erlang, :node, 0},
    {:erlang, :self, 0},
    {:erlang, :tl, 1},
    {:erlang, :tuple_size, 1},
    {:erlang, :tuple_to_list, 1},
    {:erlang, :list_to_tuple, 1},
    {:erlang, :atom_to_binary, 1},
    {:erlang, :binary_to_atom, 1},
    {:erlang, :integer_to_binary, 1},
    {:erlang, :binary_to_integer, 1},
    {:erlang, :float_to_binary, 1},
    {:erlang, :binary_to_float, 1},
    {:erlang, :term_to_binary, 1},
    {:erlang, :binary_to_term, 1},
    {:erlang, :phash2, 1},
    {:erlang, :phash2, 2},
    {:erlang, :size, 1},
    {:erlang, :bit_size, 1},
    {:erlang, :byte_size, 1},
    {:erlang, :is_atom, 1},
    {:erlang, :is_binary, 1},
    {:erlang, :is_boolean, 1},
    {:erlang, :is_float, 1},
    {:erlang, :is_integer, 1},
    {:erlang, :is_list, 1},
    {:erlang, :is_map, 1},
    {:erlang, :is_number, 1},
    {:erlang, :is_pid, 1},
    {:erlang, :is_tuple, 1}
  ]

  # --- Call classification ---

  defp classify_call(nil, function, _arity) do
    cond do
      function in @pure_kernel_functions -> :pure
      function in [:raise, :throw, :exit] -> :exception
      function in [:send] -> :send
      true -> :unknown
    end
  end

  defp classify_call(module, function, arity) do
    classify_pure(module, function, arity) ||
      classify_io(module, function) ||
      classify_messaging(module, function) ||
      classify_state(module, function) ||
      classify_exception(module, function) ||
      classify_nif(module) ||
      :unknown
  end

  @effectful_in_pure_modules [{Enum, :each, 2}, {Enum, :each, 1}]

  defp classify_pure(module, function, arity) do
    if {module, function, arity} in @effectful_in_pure_modules do
      nil
    else
      if pure_module?(module) or pure_function?(module, function, arity), do: :pure
    end
  end

  defp classify_io(module, function) do
    if io_function?(module, function), do: :io
  end

  defp classify_messaging(module, function) do
    cond do
      send_function?(module, function) -> :send
      receive_function?(module, function) -> :receive
      true -> nil
    end
  end

  defp classify_state(module, function) do
    cond do
      ets_write?(module, function) -> :write
      ets_read?(module, function) -> :read
      process_dict_write?(module, function) -> :write
      process_dict_read?(module, function) -> :read
      true -> nil
    end
  end

  defp classify_exception(module, function) do
    if exception_function?(module, function), do: :exception
  end

  defp classify_nif(module) do
    if nif_module?(module), do: :nif
  end

  # --- Pure function database ---

  defp pure_module?(module), do: module in @pure_modules

  defp pure_function?(module, function, arity) do
    {module, function, arity} in @pure_erlang_functions
  end

  defp io_function?(IO, _), do: true
  defp io_function?(File, _), do: true
  defp io_function?(Logger, _), do: true
  defp io_function?(:io, _), do: true
  defp io_function?(:file, _), do: true
  defp io_function?(_, _), do: false

  defp send_function?(_, :send), do: true
  defp send_function?(GenServer, :call), do: true
  defp send_function?(GenServer, :cast), do: true
  defp send_function?(GenServer, :reply), do: true
  defp send_function?(Process, :send), do: true
  defp send_function?(Process, :send_after), do: true
  defp send_function?(_, _), do: false

  defp receive_function?(GenServer, :handle_call), do: true
  defp receive_function?(GenServer, :handle_cast), do: true
  defp receive_function?(GenServer, :handle_info), do: true
  defp receive_function?(_, _), do: false

  defp ets_write?(:ets, f)
       when f in [:insert, :insert_new, :delete, :delete_object, :update_counter, :update_element],
       do: true

  defp ets_write?(_, _), do: false

  defp ets_read?(:ets, f)
       when f in [
              :lookup,
              :lookup_element,
              :match,
              :match_object,
              :select,
              :member,
              :info,
              :tab2list,
              :first,
              :next,
              :last,
              :prev,
              :foldl,
              :foldr
            ],
       do: true

  defp ets_read?(_, _), do: false

  defp process_dict_write?(Process, :put), do: true
  defp process_dict_write?(Process, :delete), do: true
  defp process_dict_write?(_, _), do: false

  defp process_dict_read?(Process, :get), do: true
  defp process_dict_read?(Process, :get_keys), do: true
  defp process_dict_read?(_, _), do: false

  defp exception_function?(Kernel, f) when f in [:raise, :throw, :exit], do: true
  defp exception_function?(:erlang, f) when f in [:error, :throw, :exit], do: true
  defp exception_function?(_, _), do: false

  defp nif_module?(:atomics), do: true
  defp nif_module?(:counters), do: true
  defp nif_module?(:persistent_term), do: true
  defp nif_module?(_), do: false
end
