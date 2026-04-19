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
  @compile_time_ops [
    :@, :use, :import, :alias, :require, :defstruct, :defdelegate,
    :doc, :moduledoc, :typedoc, :spec, :callback, :macrocallback, :impl,
    :type, :typep, :opaque, :behaviour,
    :"::", :defmacro, :defmacrop, :defguard, :defguardp,
    :__aliases__,
    :<<>>, :|, :\\, :when, :sigil_H, :sigil_p, :sigil_w
  ]

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

  def classify(%Node{type: :call, meta: %{kind: :field_access}}), do: :pure

  def classify(%Node{type: :call, meta: %{kind: :local, function: fun}})
      when fun in @compile_time_ops,
      do: :pure

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
    Access,
    Calendar,
    Date,
    DateTime,
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
    :re,
    NaiveDateTime,
    Time
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

  @classify_cache :reach_classify_cache

  @doc false
  def ensure_cache do
    if :ets.whereis(@classify_cache) == :undefined do
      :ets.new(@classify_cache, [:set, :public, :named_table, read_concurrency: true])
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  defp classify_call(nil, function, _arity) do
    cond do
      function in @pure_kernel_functions -> :pure
      function in [:raise, :throw, :exit] -> :exception
      function in [:send] -> :send
      true -> :unknown
    end
  end

  defp classify_call(Kernel, function, _arity) do
    cond do
      function in @pure_kernel_functions -> :pure
      function in [:raise, :throw, :exit] -> :exception
      function in [:send] -> :send
      true -> :unknown
    end
  end

  # Shared ETS cache — survives across Task.async_stream workers.
  # Assumes no hot code reloads (CLI tool, not a server).
  defp classify_call(module, function, arity) do
    key = {module, function, arity}

    case lookup_cache(key) do
      {:ok, result} ->
        result

      :miss ->
        ensure_cache()
        result = do_classify_call(module, function, arity)
        put_cache(key, result)
        result
    end
  end

  defp lookup_cache(key) do
    case :ets.lookup(@classify_cache, key) do
      [{^key, result}] -> {:ok, result}
      [] -> :miss
    end
  rescue
    ArgumentError -> :miss
  end

  defp put_cache(key, result) do
    :ets.insert(@classify_cache, {key, result})
  rescue
    ArgumentError -> :ok
  end

  defp do_classify_call(module, function, arity) do
    classify_pure(module, function, arity) ||
      classify_io(module, function) ||
      classify_messaging(module, function) ||
      classify_state(module, function) ||
      classify_exception(module, function) ||
      classify_nif(module) ||
      classify_from_spec(module, function, arity) ||
      :unknown
  end

  # Both Elixir (GenServer) and Erlang (:gen_server) atoms are listed
  # since the IR uses whichever form appears in the source code.
  @impure_modules [
    Process,
    Port,
    :erlang,
    :code,
    :ets,
    :os,
    :file,
    :gen_server,
    :gen_statem,
    :gen_event,
    :supervisor,
    :net_kernel,
    :global,
    :pg,
    :rpc,
    :public_key,
    :ssl,
    :gen_tcp,
    :gen_udp,
    :inet,
    System,
    Mix.Project,
    Mix,
    Agent,
    Node,
    Task,
    DynamicSupervisor,
    Registry,
    GenServer,
    Supervisor
  ]

  defp classify_from_spec(module, _function, _arity) when module in @impure_modules, do: nil

  defp classify_from_spec(module, function, arity) when is_atom(module) do
    case Code.Typespec.fetch_specs(module) do
      {:ok, specs} ->
        case List.keyfind(specs, {function, arity}, 0) do
          {_, clauses} -> infer_effect_from_spec(clauses)
          nil -> nil
        end

      :error ->
        nil
    end
  rescue
    _ -> nil
  end

  defp classify_from_spec(_, _, _), do: nil

  defp infer_effect_from_spec(clauses) do
    return_types = Enum.map(clauses, &extract_return_type/1)

    cond do
      Enum.all?(return_types, &ok_atom_type?/1) -> nil
      Enum.all?(return_types, &pure_return_type?/1) -> :pure
      true -> nil
    end
  end

  defp extract_return_type({:type, _, :fun, [{:type, _, :product, _}, return]}), do: return

  defp extract_return_type(
         {:type, _, :bounded_fun, [{:type, _, :fun, [{:type, _, :product, _}, return]}, _]}
       ),
       do: return

  defp extract_return_type(_), do: nil

  defp ok_atom_type?({:atom, _, :ok}), do: true
  defp ok_atom_type?(_), do: false

  defp pure_return_type?(nil), do: false
  defp pure_return_type?({:atom, _, :ok}), do: false

  defp pure_return_type?({:type, _, type, _})
       when type in [
              :integer,
              :non_neg_integer,
              :pos_integer,
              :float,
              :number,
              :binary,
              :bitstring,
              :boolean,
              :list,
              :map,
              :tuple,
              :atom,
              :module,
              :mfa,
              :arity,
              :node
            ],
       do: true

  defp pure_return_type?({:type, _, :union, subtypes}),
    do: Enum.all?(subtypes, &pure_return_type?/1)

  defp pure_return_type?({:type, _, :range, _}), do: true
  defp pure_return_type?({tag, _, _}) when tag in [:remote_type, :var, :atom], do: true
  defp pure_return_type?({:user_type, _, _, _}), do: true

  defp pure_return_type?(_), do: false

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

  @doc false
  def pure_modules, do: @pure_modules

  @doc false
  def pure_call?(module, function, arity) do
    classify_pure(module, function, arity) != nil
  end

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
       when f in [
              :new,
              :insert,
              :insert_new,
              :delete,
              :delete_all,
              :delete_object,
              :update_counter,
              :update_element,
              :match_delete,
              :select_delete,
              :rename,
              :give_away,
              :setopts,
              :safe_fixtable
            ],
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
