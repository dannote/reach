if Code.ensure_loaded?(QuickBEAM) do
  defmodule Reach.Frontend.JavaScript do
    @moduledoc """
    JavaScript source frontend — parses `.js` files into Reach IR.

    Uses QuickBEAM to compile JavaScript to QuickJS bytecode, then
    translates the decoded bytecode into Reach IR nodes.

    Only available when the `:quickbeam` package is installed.
    """

    alias Reach.IR.{Counter, Node}
    import Reach.IR.Helpers, only: [mark_as_definitions: 1]

    @spec parse(String.t(), keyword()) :: {:ok, [Node.t()]} | {:error, term()}
    def parse(source, opts \\ []) do
      file = Keyword.get(opts, :file, "nofile")
      counter = Keyword.get(opts, :counter, Counter.new())

      with {:ok, rt} <- QuickBEAM.start(apis: false) do
        try do
          case QuickBEAM.disasm(rt, source) do
            {:ok, bc} -> {:ok, translate_bytecode(bc, counter, file)}
            {:error, reason} -> {:error, reason}
          end
        rescue
          e -> {:error, Exception.message(e)}
        after
          QuickBEAM.stop(rt)
        end
      end
    end

    @spec parse!(String.t(), keyword()) :: [Node.t()]
    def parse!(source, opts \\ []) do
      case parse(source, opts) do
        {:ok, nodes} -> nodes
        {:error, reason} -> raise ArgumentError, "JS parse error: #{inspect(reason)}"
      end
    end

    @spec parse_file(Path.t(), keyword()) :: {:ok, [Node.t()]} | {:error, term()}
    def parse_file(path, opts \\ []) do
      path = Path.expand(path)

      case File.read(path) do
        {:ok, source} -> parse(source, Keyword.put_new(opts, :file, path))
        {:error, reason} -> {:error, {:file, reason}}
      end
    end

    # --- Bytecode → IR translation ---

    defp translate_bytecode(bc, counter, file) do
      Enum.map(bc.cpool, fn
        %{opcodes: _} = func -> translate_function(func, counter, file)
        _ -> nil
      end)
      |> Enum.reject(&is_nil/1)
    end

    defp translate_function(func, counter, file) do
      arg_nodes =
        func.args
        |> Enum.map(fn name ->
          %Node{
            id: Counter.next(counter),
            type: :var,
            meta: %{name: String.to_atom(name), binding_role: :definition},
            children: [],
            source_span: span(file, func.line, func.column)
          }
        end)
        |> Enum.map(&mark_as_definitions/1)

      body_nodes = translate_opcodes(func, counter, file)

      clause = %Node{
        id: Counter.next(counter),
        type: :clause,
        meta: %{kind: :function_clause},
        children: arg_nodes ++ body_nodes,
        source_span: span(file, func.line, func.column)
      }

      %Node{
        id: Counter.next(counter),
        type: :function_def,
        meta: %{
          name: String.to_atom(func.name || "<anonymous>"),
          arity: length(func.args),
          kind: :def,
          language: :javascript
        },
        children: [clause],
        source_span: span(file, func.line, func.column)
      }
    end

    # --- Opcode translation via abstract stack interpretation ---

    defp translate_opcodes(func, counter, file) do
      local_names = build_local_names(func)
      closure_names = build_closure_names(func)
      arg_names = build_arg_names(func)
      nested_fns = build_nested_fns(func, counter, file)
      line = func.line || 1
      ctx = %{locals: local_names, closures: closure_names, args: arg_names, fns: nested_fns}

      {nodes, _stack} =
        func.opcodes
        |> Enum.reduce({[], []}, fn op, {nodes, stack} ->
          translate_op(op, nodes, stack, ctx, counter, file, line)
        end)

      Enum.reverse(nodes)
    end

    defp build_local_names(func) do
      func.locals
      |> Enum.with_index()
      |> Map.new(fn {local, idx} -> {idx, String.to_atom(local["name"] || "_local#{idx}")} end)
    end

    defp build_arg_names(func) do
      func.args
      |> Enum.with_index()
      |> Map.new(fn {name, idx} -> {idx, String.to_atom(name)} end)
    end

    defp build_closure_names(func) do
      func.closure_vars
      |> Enum.with_index()
      |> Map.new(fn {cv, idx} -> {idx, String.to_atom(cv["name"] || "_closure#{idx}")} end)
    end

    defp build_nested_fns(func, counter, file) do
      func.cpool
      |> Enum.with_index()
      |> Enum.filter(fn {item, _} -> match?(%{opcodes: _}, item) end)
      |> Map.new(fn {f, idx} -> {idx, translate_function(f, counter, file)} end)
    end

    # --- Individual opcode handlers ---

    # Push constants
    defp translate_op({_, :push_0, _}, nodes, stack, _ctx, counter, _, _),
      do: {nodes, [literal(counter, 0) | stack]}

    defp translate_op({_, :push_1, _}, nodes, stack, _ctx, counter, _, _),
      do: {nodes, [literal(counter, 1) | stack]}

    defp translate_op({_, :push_2, _}, nodes, stack, _ctx, counter, _, _),
      do: {nodes, [literal(counter, 2) | stack]}

    defp translate_op({_, :push_i8, val}, nodes, stack, _ctx, counter, _, _),
      do: {nodes, [literal(counter, val) | stack]}

    defp translate_op({_, :push_i32, val}, nodes, stack, _ctx, counter, _, _),
      do: {nodes, [literal(counter, val) | stack]}

    defp translate_op({_, :push_const, val}, nodes, stack, _ctx, counter, _, _),
      do: {nodes, [literal(counter, val) | stack]}

    defp translate_op({_, :push_atom_value, val}, nodes, stack, _ctx, counter, _, _),
      do: {nodes, [literal(counter, val) | stack]}

    defp translate_op({_, :push_null}, nodes, stack, _ctx, counter, _, _),
      do: {nodes, [literal(counter, nil) | stack]}

    defp translate_op({_, :push_undefined}, nodes, stack, _ctx, counter, _, _),
      do: {nodes, [literal(counter, :undefined) | stack]}

    defp translate_op({_, :push_true}, nodes, stack, _ctx, counter, _, _),
      do: {nodes, [literal(counter, true) | stack]}

    defp translate_op({_, :push_false}, nodes, stack, _ctx, counter, _, _),
      do: {nodes, [literal(counter, false) | stack]}

    # Get/put arguments
    defp translate_op({_, op, idx}, nodes, stack, %{args: args} = _ctx, counter, file, line)
         when op in [:get_arg, :get_arg0, :get_arg1, :get_arg2, :get_arg3] do
      idx = arg_index(op, idx)
      name = Map.get(args, idx, :"arg#{idx}")
      {nodes, [var_ref(counter, name, file, line) | stack]}
    end

    # Get/put locals
    defp translate_op({_, op, idx}, nodes, stack, %{locals: locals} = _ctx, counter, file, line)
         when op in [
                :get_loc,
                :get_loc0,
                :get_loc1,
                :get_loc2,
                :get_loc3,
                :get_loc8,
                :get_loc_check
              ] do
      idx = loc_index(op, idx)
      name = Map.get(locals, idx, :"_local#{idx}")
      {nodes, [var_ref(counter, name, file, line) | stack]}
    end

    defp translate_op({_, op, idx}, nodes, stack, %{locals: locals} = _ctx, counter, file, line)
         when op in [
                :put_loc,
                :put_loc0,
                :put_loc1,
                :put_loc2,
                :put_loc3,
                :put_loc8,
                :put_loc_check,
                :put_loc_check_init,
                :set_loc_uninitialized
              ] do
      case op do
        :set_loc_uninitialized ->
          {nodes, stack}

        _ ->
          idx = loc_index(op, idx)
          name = Map.get(locals, idx, :"_local#{idx}")

          case stack do
            [value | rest] ->
              match_node = %Node{
                id: Counter.next(counter),
                type: :match,
                meta: %{},
                children: [var_def(counter, name, file, line), value],
                source_span: span(file, line, nil)
              }

              {[match_node | nodes], rest}

            [] ->
              {nodes, stack}
          end
      end
    end

    # Closure variable access
    defp translate_op(
           {_, :get_var_ref, idx},
           nodes,
           stack,
           %{closures: closures} = _ctx,
           counter,
           file,
           line
         ) do
      name = Map.get(closures, idx, :"_closure#{idx}")
      {nodes, [var_ref(counter, name, file, line) | stack]}
    end

    defp translate_op(
           {_, :put_var_ref, idx},
           nodes,
           stack,
           %{closures: closures} = _ctx,
           counter,
           file,
           line
         ) do
      name = Map.get(closures, idx, :"_closure#{idx}")

      case stack do
        [value | rest] ->
          match_node = %Node{
            id: Counter.next(counter),
            type: :match,
            meta: %{},
            children: [var_def(counter, name, file, line), value],
            source_span: span(file, line, nil)
          }

          {[match_node | nodes], rest}

        [] ->
          {nodes, stack}
      end
    end

    # Binary operators
    @binary_ops %{
      add: :+,
      mul: :*,
      sub: :-,
      div: :/,
      mod: :%,
      pow: :**,
      eq: :==,
      neq: :!=,
      strict_eq: :===,
      strict_neq: :!==,
      lt: :<,
      lte: :<=,
      gt: :>,
      gte: :>=,
      shl: :"<<",
      sar: :">>",
      shr: :>>>,
      and: :&,
      or: :|,
      xor: :^,
      in: :in,
      instanceof: :instanceof
    }

    for {opname, operator} <- @binary_ops do
      defp translate_op({_, unquote(opname)}, nodes, stack, _ctx, counter, file, line) do
        case stack do
          [right, left | rest] ->
            node = %Node{
              id: Counter.next(counter),
              type: :binary_op,
              meta: %{operator: unquote(operator)},
              children: [left, right],
              source_span: span(file, line, nil)
            }

            {nodes, [node | rest]}

          _ ->
            {nodes, stack}
        end
      end
    end

    # Unary operators
    @unary_ops %{
      neg: :-,
      plus: :+,
      not: :!,
      bnot: :"~",
      typeof: :typeof,
      void: :void
    }

    for {opname, operator} <- @unary_ops do
      defp translate_op({_, unquote(opname)}, nodes, stack, _ctx, counter, file, line) do
        case stack do
          [operand | rest] ->
            node = %Node{
              id: Counter.next(counter),
              type: :unary_op,
              meta: %{operator: unquote(operator)},
              children: [operand],
              source_span: span(file, line, nil)
            }

            {nodes, [node | rest]}

          _ ->
            {nodes, stack}
        end
      end
    end

    # Increment/decrement
    defp translate_op({_, op}, nodes, stack, _ctx, counter, file, line)
         when op in [:inc, :dec, :post_inc, :post_dec] do
      case stack do
        [operand | rest] ->
          operator = if op in [:inc, :post_inc], do: :++, else: :--

          node = %Node{
            id: Counter.next(counter),
            type: :unary_op,
            meta: %{operator: operator},
            children: [operand],
            source_span: span(file, line, nil)
          }

          {nodes, [node | rest]}

        _ ->
          {nodes, stack}
      end
    end

    # Function calls
    defp translate_op({_, op, argc}, nodes, stack, _ctx, counter, file, line)
         when op in [:call, :call0, :call1, :call2, :call3, :tail_call] do
      argc = call_argc(op, argc)

      case safe_pop(stack, argc + 1) do
        {[func | args], rest} ->
          call_node = %Node{
            id: Counter.next(counter),
            type: :call,
            meta: %{
              function: extract_name(func),
              arity: argc,
              kind: :local
            },
            children: args,
            source_span: span(file, line, nil)
          }

          {nodes, [call_node | rest]}

        :error ->
          {nodes, stack}
      end
    end

    # Method calls
    defp translate_op({_, op, argc}, nodes, stack, _ctx, counter, file, line)
         when op in [:call_method, :tail_call_method] do
      case safe_pop(stack, argc + 2) do
        {[obj, method | args], rest} ->
          call_node = %Node{
            id: Counter.next(counter),
            type: :call,
            meta: %{
              module: extract_name(obj),
              function: extract_name(method),
              arity: argc,
              kind: :remote
            },
            children: args,
            source_span: span(file, line, nil)
          }

          {nodes, [call_node | rest]}

        :error ->
          {nodes, stack}
      end
    end

    # Return
    defp translate_op({_, :return}, nodes, stack, _ctx, _counter, _file, _line) do
      case stack do
        [value | rest] -> {[value | nodes], rest}
        [] -> {nodes, stack}
      end
    end

    defp translate_op({_, :return_undef}, nodes, stack, _ctx, counter, _, _) do
      {[literal(counter, :undefined) | nodes], stack}
    end

    # Control flow — if_false / goto
    defp translate_op({_, op, _target}, nodes, stack, _ctx, _counter, _file, _line)
         when op in [:if_false, :if_true, :if_false8, :if_true8] do
      case stack do
        [_condition | rest] -> {nodes, rest}
        [] -> {nodes, stack}
      end
    end

    defp translate_op({_, :goto, _target}, nodes, stack, _ctx, _, _, _),
      do: {nodes, stack}

    defp translate_op({_, :goto8, _target}, nodes, stack, _ctx, _, _, _),
      do: {nodes, stack}

    # Object construction
    defp translate_op({_, :object}, nodes, stack, _ctx, counter, file, line) do
      node = %Node{
        id: Counter.next(counter),
        type: :map,
        meta: %{kind: :object},
        children: [],
        source_span: span(file, line, nil)
      }

      {nodes, [node | stack]}
    end

    defp translate_op(
           {_, :define_field, name},
           nodes,
           [value, obj | rest],
           _ctx,
           counter,
           file,
           line
         ) do
      field_node = %Node{
        id: Counter.next(counter),
        type: :map_field,
        meta: %{key: String.to_atom(name)},
        children: [value],
        source_span: span(file, line, nil)
      }

      updated = %{obj | children: obj.children ++ [field_node]}
      {nodes, [updated | rest]}
    end

    # Property access
    defp translate_op({_, :get_field2, name}, nodes, stack, _ctx, counter, file, line) do
      case stack do
        [obj | rest] ->
          node = %Node{
            id: Counter.next(counter),
            type: :call,
            meta: %{function: String.to_atom(name), kind: :field_access},
            children: [obj],
            source_span: span(file, line, nil)
          }

          {nodes, [node | rest]}

        [] ->
          {nodes, stack}
      end
    end

    # Closures
    defp translate_op(
           {_, op, idx},
           nodes,
           stack,
           %{fns: nested_fns} = _ctx,
           _counter,
           _file,
           _line
         )
         when op in [:fclosure, :fclosure8] do
      case Map.get(nested_fns, idx) do
        nil -> {nodes, stack}
        fn_node -> {nodes, [fn_node | stack]}
      end
    end

    # Stack manipulation
    defp translate_op({_, :dup}, nodes, [top | rest], _ctx, _, _, _),
      do: {nodes, [top, top | rest]}

    defp translate_op({_, :drop}, nodes, [_ | rest], _ctx, _, _, _),
      do: {nodes, rest}

    defp translate_op({_, :nip}, nodes, [top, _ | rest], _ctx, _, _, _),
      do: {nodes, [top | rest]}

    defp translate_op({_, :swap}, nodes, [a, b | rest], _ctx, _, _, _),
      do: {nodes, [b, a | rest]}

    # Set name (used for function/property naming, skip)
    defp translate_op({_, :set_name, _}, nodes, stack, _ctx, _, _, _),
      do: {nodes, stack}

    # Throw
    defp translate_op({_, :throw}, nodes, stack, _ctx, counter, file, line) do
      case stack do
        [value | rest] ->
          node = %Node{
            id: Counter.next(counter),
            type: :call,
            meta: %{function: :throw, kind: :local},
            children: [value],
            source_span: span(file, line, nil)
          }

          {[node | nodes], rest}

        [] ->
          {nodes, stack}
      end
    end

    # Array literal
    defp translate_op({_, :array_from, count}, nodes, stack, _ctx, counter, file, line) do
      case safe_pop(stack, count) do
        {elements, rest} ->
          node = %Node{
            id: Counter.next(counter),
            type: :list,
            meta: %{kind: :array},
            children: elements,
            source_span: span(file, line, nil)
          }

          {nodes, [node | rest]}

        :error ->
          {nodes, stack}
      end
    end

    # Constructor call
    defp translate_op({_, :call_constructor, argc}, nodes, stack, _ctx, counter, file, line) do
      case safe_pop(stack, argc + 2) do
        {[_new_target, constructor | args], rest} ->
          node = %Node{
            id: Counter.next(counter),
            type: :call,
            meta: %{function: extract_name(constructor), arity: argc, kind: :constructor},
            children: args,
            source_span: span(file, line, nil)
          }

          {nodes, [node | rest]}

        :error ->
          {nodes, stack}
      end
    end

    # Catch-all for unhandled opcodes
    defp translate_op(_op, nodes, stack, _ctx, _counter, _file, _line) do
      {nodes, stack}
    end

    # --- Helpers ---

    defp literal(counter, value) do
      %Node{id: Counter.next(counter), type: :literal, meta: %{value: value}, children: []}
    end

    defp var_ref(counter, name, file, line) do
      %Node{
        id: Counter.next(counter),
        type: :var,
        meta: %{name: name},
        children: [],
        source_span: span(file, line, nil)
      }
    end

    defp var_def(counter, name, file, line) do
      %Node{
        id: Counter.next(counter),
        type: :var,
        meta: %{name: name, binding_role: :definition},
        children: [],
        source_span: span(file, line, nil)
      }
    end

    defp span(_file, nil, _col), do: nil

    defp span(file, line, col) do
      %{file: file, start_line: line, start_col: col, end_line: nil, end_col: nil}
    end

    defp extract_name(%Node{type: :var, meta: %{name: name}}), do: name

    defp extract_name(%Node{type: :literal, meta: %{value: v}}) when is_binary(v),
      do: String.to_atom(v)

    defp extract_name(%Node{type: :literal, meta: %{value: v}}) when is_atom(v), do: v
    defp extract_name(%Node{type: :call, meta: %{function: f}}), do: f
    defp extract_name(%Node{type: :function_def, meta: %{name: n}}), do: n
    defp extract_name(_), do: :unknown

    defp arg_index(:get_arg0, _), do: 0
    defp arg_index(:get_arg1, _), do: 1
    defp arg_index(:get_arg2, _), do: 2
    defp arg_index(:get_arg3, _), do: 3
    defp arg_index(:get_arg, idx), do: idx

    defp loc_index(:get_loc0, _), do: 0
    defp loc_index(:put_loc0, _), do: 0
    defp loc_index(:get_loc1, _), do: 1
    defp loc_index(:put_loc1, _), do: 1
    defp loc_index(:get_loc2, _), do: 2
    defp loc_index(:put_loc2, _), do: 2
    defp loc_index(:get_loc3, _), do: 3
    defp loc_index(:put_loc3, _), do: 3
    defp loc_index(_, idx), do: idx

    defp call_argc(:call0, _), do: 0
    defp call_argc(:call1, _), do: 1
    defp call_argc(:call2, _), do: 2
    defp call_argc(:call3, _), do: 3
    defp call_argc(_, argc), do: argc

    defp safe_pop(stack, n) do
      if length(stack) >= n do
        {Enum.take(stack, n), Enum.drop(stack, n)}
      else
        :error
      end
    end
  end
end
