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
      source = prepare_source(source, file)

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

    defp prepare_source(source, file) do
      source
      |> maybe_strip_types(file)
      |> strip_module_syntax()
    end

    defp maybe_strip_types(source, file) do
      if String.ends_with?(to_string(file), [".ts", ".tsx"]) and Code.ensure_loaded?(OXC) do
        case OXC.transform(source, Path.basename(to_string(file)), sourcemap: false) do
          {:ok, js} when is_binary(js) -> js
          {:ok, %{code: js}} -> js
          _ -> source
        end
      else
        source
      end
    end

    defp strip_module_syntax(source) do
      if Code.ensure_loaded?(OXC) do
        patch_module_syntax(source)
      else
        source
      end
    end

    defp patch_module_syntax(source) do
      case OXC.parse(source, "module.js") do
        {:ok, ast} ->
          patches = Enum.flat_map(ast.body, &module_syntax_patch/1)
          if patches == [], do: source, else: OXC.patch_string(source, patches)

        {:error, _} ->
          source
      end
    end

    defp module_syntax_patch(%{type: t} = node)
         when t in [:export_named_declaration, :export_default_declaration] do
      case Map.get(node, :declaration) do
        nil -> [%{start: node.start, end: node[:end], change: ""}]
        decl -> [%{start: node.start, end: decl.start, change: ""}]
      end
    end

    defp module_syntax_patch(%{type: :import_declaration} = node) do
      [%{start: node.start, end: node[:end], change: ""}]
    end

    defp module_syntax_patch(_), do: []

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
      nested =
        Enum.map(bc.cpool, fn
          %{opcodes: _} = func -> translate_function(func, counter, file)
          _ -> nil
        end)
        |> Enum.reject(&is_nil/1)

      if has_module_level_code?(bc) do
        top = translate_function(%{bc | name: "<module>"}, counter, file)
        [top | nested]
      else
        nested
      end
    end

    defp has_module_level_code?(bc) do
      bc.name in ["<eval>", nil, ""] and
        Enum.any?(bc.opcodes, fn op ->
          elem(op, 1) not in [
            :check_define_var,
            :define_func,
            :fclosure,
            :fclosure8,
            :get_loc0,
            :get_loc,
            :return,
            :set_loc_uninitialized,
            :put_loc,
            :put_loc0,
            :put_loc1
          ]
        end)
    end

    defp translate_function(func, counter, file) do
      start_line = func.line || 1
      end_line = start_line + source_line_count(func.source) - 1

      fn_span = %{
        file: file,
        start_line: start_line,
        start_col: func.column,
        end_line: end_line,
        end_col: nil
      }

      arg_nodes =
        func.args
        |> Enum.map(fn name ->
          %Node{
            id: Counter.next(counter),
            type: :var,
            meta: %{name: String.to_atom(name), binding_role: :definition},
            children: [],
            source_span: fn_span
          }
        end)
        |> Enum.map(&mark_as_definitions/1)

      body_nodes = translate_opcodes(func, counter, file)

      clause = %Node{
        id: Counter.next(counter),
        type: :clause,
        meta: %{kind: :function_clause},
        children: arg_nodes ++ body_nodes,
        source_span: fn_span
      }

      %Node{
        id: Counter.next(counter),
        type: :function_def,
        meta: %{
          name: String.to_atom(func.name || "<anonymous>"),
          arity: length(func.args),
          kind: :def,
          language: :javascript,
          source: func.source
        },
        children: [clause],
        source_span: fn_span
      }
    end

    defp source_line_count(nil), do: 1
    defp source_line_count(source), do: source |> String.split("\n") |> length()

    # --- Opcode translation via abstract stack interpretation ---

    defp translate_opcodes(func, counter, file) do
      local_names = build_local_names(func)
      closure_names = build_closure_names(func)
      arg_names = build_arg_names(func)
      nested_fns = build_nested_fns(func, counter, file)
      ctx = %{locals: local_names, closures: closure_names, args: arg_names, fns: nested_fns}
      env = %{ctx: ctx, counter: counter, file: file}

      branch_targets = collect_branch_targets(func.opcodes)
      blocks = split_into_blocks(func.opcodes, branch_targets)
      fall_through_targets = collect_fall_through_targets(blocks)

      block_map =
        blocks
        |> Enum.map(fn ops -> {elem(hd(ops), 0), ops} end)
        |> Map.new()

      processed = MapSet.new()
      base_line = func.line || 1
      max_lines = source_line_count(func.source)

      {all_nodes, _, _} =
        blocks
        |> Enum.with_index()
        |> Enum.reduce({[], [], processed}, fn {block_ops, block_idx}, acc ->
          block_line = base_line + min(block_idx + 1, max_lines - 1)

          reduce_block(
            block_ops,
            block_map,
            acc,
            branch_targets,
            fall_through_targets,
            env,
            block_line
          )
        end)

      all_nodes
    end

    defp reduce_block(
           block_ops,
           block_map,
           {acc_nodes, prev_stack, visited},
           targets,
           fall_through,
           env,
           line
         ) do
      first_offset = elem(hd(block_ops), 0)

      if MapSet.member?(visited, first_offset) do
        {acc_nodes, prev_stack, visited}
      else
        stack =
          if MapSet.member?(targets, first_offset) and
               not MapSet.member?(fall_through, first_offset),
             do: [],
             else: prev_stack

        process_block(block_ops, block_map, stack, acc_nodes, visited, env, line)
      end
    end

    defp process_block(block_ops, block_map, stack, acc_nodes, visited, env, line) do
      first_offset = elem(hd(block_ops), 0)

      case detect_if_else(block_ops, block_map) do
        {:if_else, condition_ops, true_ops, false_ops} ->
          {new_nodes, body_stack, new_visited} =
            build_if_else(condition_ops, true_ops, false_ops, stack, visited, env, line)

          {acc_nodes ++ new_nodes, body_stack, MapSet.put(new_visited, first_offset)}

        nil ->
          {nodes, stack} = run_block(block_ops, stack, env, line)
          {acc_nodes ++ nodes, stack, MapSet.put(visited, first_offset)}
      end
    end

    defp build_if_else(condition_ops, true_ops, false_ops, stack, visited, env, line) do
      %{counter: counter, file: file} = env

      {cond_nodes, cond_stack} = run_block(condition_ops, stack, env, line)
      {condition, body_stack} = pop_condition(cond_stack)

      {true_nodes, _} = run_block(true_ops, body_stack, env, line)
      {false_nodes, _} = run_block(false_ops, body_stack, env, line)
      case_span = span(file, line, nil)

      case_node = %Node{
        id: Counter.next(counter),
        type: :case,
        meta: %{desugared_from: :if},
        children: [
          condition,
          %Node{
            id: Counter.next(counter),
            type: :clause,
            meta: %{kind: :true_branch},
            children: true_nodes,
            source_span: case_span
          },
          %Node{
            id: Counter.next(counter),
            type: :clause,
            meta: %{kind: :false_branch},
            children: false_nodes,
            source_span: case_span
          }
        ],
        source_span: case_span
      }

      visited = visited |> mark_visited(true_ops) |> mark_visited(false_ops)
      {cond_nodes ++ [case_node], body_stack, visited}
    end

    defp run_block(ops, stack, env, line) do
      %{ctx: ctx, counter: counter, file: file} = env

      {nodes, stack} =
        Enum.reduce(ops, {[], stack}, fn op, {nodes, stack} ->
          translate_op(op, nodes, stack, ctx, counter, file, line)
        end)

      {Enum.reverse(nodes) ++ Enum.reverse(stack), stack}
    end

    defp pop_condition([top | rest]), do: {top, rest}
    defp pop_condition([]), do: {literal(Counter.new(), nil), []}

    defp mark_visited(visited, ops) do
      Enum.reduce(ops, visited, fn op, v -> MapSet.put(v, elem(op, 0)) end)
    end

    defp detect_if_else(block_ops, block_map) do
      last = block_ops |> Enum.reverse() |> List.first()

      with {_, kind, target} when kind in [:if_false, :if_false8] <- last,
           condition_ops = Enum.drop(block_ops, -1),
           true_offset = find_next_block_offset(block_map, elem(last, 0)),
           true_block when true_block != nil <- Map.get(block_map, true_offset),
           true_last = true_block |> Enum.reverse() |> List.first(),
           true when true <- terminal?(true_last),
           false_block when false_block != nil <- Map.get(block_map, target) do
        {:if_else, condition_ops, true_block, false_block}
      else
        _ -> nil
      end
    end

    defp find_next_block_offset(block_map, branch_offset) do
      block_map
      |> Map.keys()
      |> Enum.filter(&(&1 > branch_offset))
      |> Enum.min(fn -> nil end)
    end

    @js_terminal_ops [
      :return,
      :return_undef,
      :return_async,
      :throw,
      :tail_call,
      :tail_call_method
    ]
    @js_branch_ops [:if_false, :if_true, :if_false8, :if_true8, :goto, :goto8, :goto16]

    defp terminal?({_, op}) when op in @js_terminal_ops, do: true
    defp terminal?({_, op, _}) when op in @js_branch_ops, do: true
    defp terminal?({_, op, _}) when op in @js_terminal_ops, do: true
    defp terminal?(_), do: false

    @branch_ops [:if_false, :if_true, :if_false8, :if_true8, :goto, :goto8, :goto16, :catch]
    @terminal_ops [:return, :return_undef, :return_async, :throw, :tail_call, :tail_call_method]

    defp collect_branch_targets(opcodes) do
      indexed = Enum.with_index(opcodes)

      indexed
      |> Enum.flat_map(fn {op, idx} ->
        next_offset = next_op_offset(indexed, idx)

        case op do
          {_, kind, target} when kind in @branch_ops -> [target | List.wrap(next_offset)]
          {_, kind} when kind in @terminal_ops -> List.wrap(next_offset)
          _ -> []
        end
      end)
      |> MapSet.new()
    end

    defp next_op_offset(indexed, idx) do
      case Enum.at(indexed, idx + 1) do
        {next_op, _} -> elem(next_op, 0)
        nil -> nil
      end
    end

    defp collect_fall_through_targets(blocks) do
      blocks
      |> Enum.chunk_every(2, 1, [])
      |> Enum.flat_map(fn
        [prev_block, [next_op | _]] ->
          last_op = prev_block |> Enum.reverse() |> List.first()

          falls_through =
            elem(last_op, 1) not in [
              :goto,
              :goto8,
              :goto16,
              :return,
              :return_undef,
              :return_async,
              :throw,
              :tail_call,
              :tail_call_method
            ]

          if falls_through, do: [elem(next_op, 0)], else: []

        _ ->
          []
      end)
      |> MapSet.new()
    end

    defp split_into_blocks(opcodes, targets) do
      {blocks, current} =
        Enum.reduce(opcodes, {[], []}, fn op, {blocks, current} ->
          offset = elem(op, 0)

          if MapSet.member?(targets, offset) and current != [] do
            {blocks ++ [Enum.reverse(current)], [op]}
          else
            {blocks, [op | current]}
          end
        end)

      if current == [], do: blocks, else: blocks ++ [Enum.reverse(current)]
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

    defp translate_op({_, :push_3, _}, nodes, stack, _ctx, counter, _, _),
      do: {nodes, [literal(counter, 3) | stack]}

    defp translate_op({_, :push_4, _}, nodes, stack, _ctx, counter, _, _),
      do: {nodes, [literal(counter, 4) | stack]}

    defp translate_op({_, :push_5, _}, nodes, stack, _ctx, counter, _, _),
      do: {nodes, [literal(counter, 5) | stack]}

    defp translate_op({_, :push_6, _}, nodes, stack, _ctx, counter, _, _),
      do: {nodes, [literal(counter, 6) | stack]}

    defp translate_op({_, :push_minus1, _}, nodes, stack, _ctx, counter, _, _),
      do: {nodes, [literal(counter, -1) | stack]}

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
          emit_assignment(nodes, stack, name, counter, file, line)
      end
    end

    # Global variable access
    defp translate_op({_, :get_var, name}, nodes, stack, _ctx, counter, file, line) do
      {nodes, [var_ref(counter, String.to_atom(name), file, line) | stack]}
    end

    defp translate_op({_, :push_empty_string}, nodes, stack, _ctx, counter, _, _),
      do: {nodes, [literal(counter, "") | stack]}

    defp translate_op({_, :push_this}, nodes, stack, _ctx, counter, file, line),
      do: {nodes, [var_ref(counter, :this, file, line) | stack]}

    defp translate_op({_, :is_undefined_or_null}, nodes, stack, _ctx, _counter, _file, _line),
      do: {nodes, stack}

    # More push variants
    defp translate_op({_, :undefined}, nodes, stack, _ctx, counter, _, _),
      do: {nodes, [literal(counter, :undefined) | stack]}

    defp translate_op({_, :null}, nodes, stack, _ctx, counter, _, _),
      do: {nodes, [literal(counter, nil) | stack]}

    defp translate_op({_, :push_i16, val}, nodes, stack, _ctx, counter, _, _),
      do: {nodes, [literal(counter, val) | stack]}

    # Logical NOT
    defp translate_op({_, :lnot}, nodes, stack, _ctx, counter, file, line) do
      case stack do
        [operand | rest] ->
          node = %Node{
            id: Counter.next(counter),
            type: :unary_op,
            meta: %{operator: :!},
            children: [operand],
            source_span: span(file, line, nil)
          }

          {nodes, [node | rest]}

        _ ->
          {nodes, stack}
      end
    end

    # Property write: obj.field = value
    defp translate_op({_, :put_field, name}, nodes, stack, _ctx, counter, file, line) do
      case stack do
        [value, obj | rest] ->
          node = %Node{
            id: Counter.next(counter),
            type: :call,
            meta: %{function: String.to_atom(name), kind: :field_write, module: extract_name(obj)},
            children: [obj, value],
            source_span: span(file, line, nil)
          }

          {[node | nodes], rest}

        _ ->
          {nodes, stack}
      end
    end

    # Method definition in object literal
    defp translate_op({_, :define_method, name, _flags}, nodes, stack, _ctx, counter, file, line) do
      case stack do
        [func, obj | rest] ->
          field_node = %Node{
            id: Counter.next(counter),
            type: :map_field,
            meta: %{key: String.to_atom(name)},
            children: [func],
            source_span: span(file, line, nil)
          }

          updated = %{obj | children: obj.children ++ [field_node]}
          {nodes, [updated | rest]}

        _ ->
          {nodes, stack}
      end
    end

    # Global variable write
    defp translate_op({_, :put_var, name}, nodes, stack, _ctx, counter, file, line) do
      emit_assignment(nodes, stack, String.to_atom(name), counter, file, line)
    end

    # Argument mutation
    defp translate_op({_, op, idx}, nodes, stack, _ctx, counter, file, line)
         when op in [:put_arg, :put_arg0, :put_arg1, :put_arg2, :put_arg3] do
      idx = arg_index(op, idx)
      emit_assignment(nodes, stack, :"arg#{idx}", counter, file, line)
    end

    # Variable access variants
    defp translate_op({_, :get_var_undef, name}, nodes, stack, _ctx, counter, file, line),
      do: {nodes, [var_ref(counter, String.to_atom(name), file, line) | stack]}

    defp translate_op(
           {_, :get_var_ref1, idx},
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

    # Control flow variants
    defp translate_op({_, :goto16, _}, nodes, stack, _ctx, _counter, _file, _line),
      do: {nodes, stack}

    # Try/catch — for IR purposes, catch pushes exception on stack
    defp translate_op({_, :catch, _}, nodes, stack, _ctx, counter, file, line),
      do: {nodes, [var_ref(counter, :"<exception>", file, line) | stack]}

    defp translate_op({_, :nip_catch}, nodes, stack, _ctx, _counter, _file, _line) do
      case stack do
        [top, _ | rest] -> {nodes, [top | rest]}
        _ -> {nodes, stack}
      end
    end

    # For-of loops
    defp translate_op({_, :for_of_start}, nodes, stack, _ctx, _counter, _file, _line) do
      case stack do
        [iterable | rest] -> {nodes, [iterable, iterable, iterable | rest]}
        _ -> {nodes, stack}
      end
    end

    defp translate_op({_, :for_of_next, _}, nodes, stack, _ctx, counter, file, line) do
      case stack do
        [_iter, _obj, _method | rest] ->
          {nodes, [literal(counter, false), var_ref(counter, :"<iter_value>", file, line) | rest]}

        _ ->
          {nodes, stack}
      end
    end

    defp translate_op({_, :iterator_close}, nodes, stack, _ctx, _counter, _file, _line) do
      case stack do
        [_, _, _ | rest] -> {nodes, rest}
        _ -> {nodes, stack}
      end
    end

    # Array/object operations
    defp translate_op({_, :get_length}, nodes, stack, _ctx, counter, file, line) do
      case stack do
        [obj | rest] ->
          node = %Node{
            id: Counter.next(counter),
            type: :call,
            meta: %{function: :length, kind: :field_access},
            children: [obj],
            source_span: span(file, line, nil)
          }

          {nodes, [node | rest]}

        _ ->
          {nodes, stack}
      end
    end

    defp translate_op({_, :get_array_el}, nodes, stack, _ctx, counter, file, line) do
      case stack do
        [index, arr | rest] ->
          {nodes, [make_array_access(counter, arr, index, file, line) | rest]}

        _ ->
          {nodes, stack}
      end
    end

    defp translate_op({_, :get_array_el2}, nodes, stack, _ctx, counter, file, line) do
      case stack do
        [index, arr | rest] ->
          {nodes, [make_array_access(counter, arr, index, file, line), arr | rest]}

        _ ->
          {nodes, stack}
      end
    end

    defp translate_op(
           {_, :get_loc0_loc1},
           nodes,
           stack,
           %{locals: locals} = _ctx,
           counter,
           file,
           line
         ) do
      name0 = Map.get(locals, 0, :_local0)
      name1 = Map.get(locals, 1, :_local1)
      {nodes, [var_ref(counter, name1, file, line), var_ref(counter, name0, file, line) | stack]}
    end

    defp translate_op({_, :check_define_var, _, _}, nodes, stack, _ctx, _, _, _),
      do: {nodes, stack}

    defp translate_op({_, :define_func, _, _}, nodes, stack, _ctx, _, _, _) do
      case stack do
        [_ | rest] -> {nodes, rest}
        _ -> {nodes, stack}
      end
    end

    # Type checks — leave value on stack, result replaces it
    defp translate_op({_, op}, nodes, stack, _ctx, _counter, _file, _line)
         when op in [:typeof_is_function, :typeof_is_undefined, :is_undefined, :to_object],
         do: {nodes, stack}

    # Dynamic import — pops specifier, pushes promise
    defp translate_op({_, :import}, nodes, stack, _ctx, counter, file, line) do
      case stack do
        [_specifier, _obj | rest] ->
          node = %Node{
            id: Counter.next(counter),
            type: :call,
            meta: %{function: :import, kind: :local, arity: 1},
            children: [],
            source_span: span(file, line, nil)
          }

          {nodes, [node | rest]}

        _ ->
          {nodes, stack}
      end
    end

    # Stack permutations
    defp translate_op({_, :perm3}, nodes, [a, b, c | rest], _ctx, _, _, _),
      do: {nodes, [b, c, a | rest]}

    defp translate_op({_, :rest, _}, nodes, stack, _ctx, counter, file, line) do
      case stack do
        [arr | rest] ->
          node = %Node{
            id: Counter.next(counter),
            type: :call,
            meta: %{function: :..., kind: :local},
            children: [arr],
            source_span: span(file, line, nil)
          }

          {nodes, [node | rest]}

        _ ->
          {nodes, stack}
      end
    end

    # Closure variable access
    defp translate_op(
           {_, op, idx},
           nodes,
           stack,
           %{closures: closures} = _ctx,
           counter,
           file,
           line
         )
         when op in [:get_var_ref, :get_var_ref_check] do
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
      emit_assignment(nodes, stack, name, counter, file, line)
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
        {popped, rest} ->
          [func | args] = Enum.reverse(popped)

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

    # Method calls — stack order (top→bottom): argN..arg0, method, obj
    defp translate_op({_, op, argc}, nodes, stack, _ctx, counter, file, line)
         when op in [:call_method, :tail_call_method] do
      case safe_pop(stack, argc + 2) do
        {popped, rest} ->
          [obj, method | args] = Enum.reverse(popped)
          {nodes, [build_method_call(obj, method, args, counter, file, line) | rest]}

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

    defp translate_op({_, :return_async}, nodes, stack, _ctx, _counter, _file, _line) do
      case stack do
        [value | rest] -> {[value | nodes], rest}
        [] -> {nodes, stack}
      end
    end

    # Await — for IR purposes, same value passes through
    defp translate_op({_, :await}, nodes, stack, _ctx, _counter, _file, _line),
      do: {nodes, stack}

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

    # Property access (get_field pushes value, get_field2 pushes obj + value for method calls)
    defp translate_op({_, :get_field, name}, nodes, stack, _ctx, counter, file, line) do
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

    defp translate_op({_, :get_field2, name}, nodes, stack, _ctx, counter, file, line) do
      case stack do
        [obj | rest] ->
          method = %Node{
            id: Counter.next(counter),
            type: :literal,
            meta: %{value: name},
            children: [],
            source_span: span(file, line, nil)
          }

          {nodes, [method, obj | rest]}

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

    defp translate_op({_, :drop}, nodes, [top | rest], _ctx, _, _, _) do
      case top.type do
        :call -> {[top | nodes], rest}
        :match -> {[top | nodes], rest}
        _ -> {nodes, rest}
      end
    end

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

    # --- Method call helpers ---

    defp build_method_call(
           %Node{type: :literal, meta: %{value: str}},
           %Node{type: :literal, meta: %{value: "concat"}},
           args,
           counter,
           file,
           line
         )
         when is_binary(str) do
      parts = [literal(counter, str) | args]

      Enum.reduce(tl(parts), hd(parts), fn right, left ->
        %Node{
          id: Counter.next(counter),
          type: :binary_op,
          meta: %{operator: :+},
          children: [left, right],
          source_span: span(file, line, nil)
        }
      end)
    end

    defp build_method_call(obj, method, args, counter, file, line) do
      %Node{
        id: Counter.next(counter),
        type: :call,
        meta: %{
          module: extract_name(obj),
          function: extract_name(method),
          arity: length(args),
          kind: :remote
        },
        children: args,
        source_span: span(file, line, nil)
      }
    end

    # --- Helpers ---

    defp emit_assignment(nodes, stack, name, counter, file, line) do
      case stack do
        [value | rest] ->
          node = %Node{
            id: Counter.next(counter),
            type: :match,
            meta: %{},
            children: [var_def(counter, name, file, line), value],
            source_span: span(file, line, nil)
          }

          {[node | nodes], rest}

        [] ->
          {nodes, stack}
      end
    end

    defp make_array_access(counter, arr, index, file, line) do
      %Node{
        id: Counter.next(counter),
        type: :call,
        meta: %{function: :"[]", kind: :field_access},
        children: [arr, index],
        source_span: span(file, line, nil)
      }
    end

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
    defp arg_index(:put_arg0, _), do: 0
    defp arg_index(:put_arg1, _), do: 1
    defp arg_index(:put_arg2, _), do: 2
    defp arg_index(:put_arg3, _), do: 3
    defp arg_index(:get_arg, idx), do: idx
    defp arg_index(:put_arg, idx), do: idx

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
