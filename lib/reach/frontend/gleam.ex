defmodule Reach.Frontend.Gleam do
  @moduledoc """
  Gleam source frontend — parses `.gleam` files into Reach IR.

  Uses the `glance` Gleam parser (if available on the code path) for
  accurate AST with byte-offset spans. Falls back to analyzing the
  generated Erlang output when glance is not available.

  To enable native parsing, build glance and add its ebin to your path:

      git clone https://github.com/lpil/glance /tmp/glance
      cd /tmp/glance && gleam build --target erlang
      # glance beams are in /tmp/glance/build/dev/erlang/*/ebin/
  """

  alias Reach.IR.{Counter, Node}
  import Reach.IR.Helpers, only: [mark_as_definitions: 1]

  @spec parse_file(Path.t(), keyword()) :: {:ok, [Node.t()]} | {:error, term()}
  def extensions, do: [".gleam"]

  def parse_file(gleam_path, opts \\ []) do
    gleam_path = Path.expand(gleam_path)

    case File.read(gleam_path) do
      {:ok, source} ->
        ensure_glance!()
        parse_with_glance(source, gleam_path, opts)

      {:error, reason} ->
        {:error, {:file, reason}}
    end
  end

  defp ensure_glance! do
    if :code.which(:glance) == :non_existing do
      glance_paths = Path.wildcard("/tmp/glance/build/dev/erlang/*/ebin")

      if glance_paths == [] do
        raise "glance parser not found. Install it:\n\n  git clone https://github.com/lpil/glance /tmp/glance\n  cd /tmp/glance && gleam build --target erlang"
      end

      for p <- glance_paths, do: :code.add_patha(to_charlist(p))
    end
  end

  # ── Native glance parser ──

  defp parse_with_glance(source, file, opts) do
    # credo:disable-for-next-line Credo.Check.Refactor.Apply
    case apply(:glance, :module, [source]) do
      {:ok, {:module, _imports, _types, _aliases, _consts, functions}} ->
        line_offsets = build_line_offsets(source)
        counter = Keyword.get(opts, :counter, Counter.new())

        nodes =
          functions
          |> Enum.map(fn {:definition, _attrs, func} ->
            translate_function(func, counter, file, line_offsets)
          end)

        populate_def_cache(file, functions, line_offsets)

        {:ok, nodes}

      {:error, err} ->
        {:error, {:gleam_parse, err}}
    end
  end

  defp populate_def_cache(file, functions, offsets) do
    line_map =
      Map.new(functions, fn {:definition, _attrs, {:function, {:span, s, e}, _name, _, _, _, _}} ->
        start_line = byte_to_line(offsets, s)
        end_line = byte_to_line(offsets, max(e - 1, s))
        {start_line, end_line}
      end)

    cache = Process.get(:reach_def_end_cache, %{})
    Process.put(:reach_def_end_cache, Map.put(cache, file, line_map))
  end

  def build_line_offsets(source) do
    {offsets, _} =
      source
      |> String.split("\n")
      |> Enum.reduce({[0], 0}, fn line, {starts, offset} ->
        next = offset + byte_size(line) + 1
        {[next | starts], next}
      end)

    Enum.reverse(offsets)
  end

  def byte_to_line(offsets, byte_offset) do
    Enum.find_index(offsets, fn start -> start > byte_offset end) || length(offsets)
  end

  defp span(offsets, {:span, start, end_byte}, file) do
    %{
      file: file,
      start_line: byte_to_line(offsets, start),
      start_col: nil,
      end_line: byte_to_line(offsets, max(end_byte - 1, start)),
      end_col: nil
    }
  end

  defp span(_, _, _), do: nil

  # ── Function translation ──

  defp translate_function(
         {:function, loc, name, publicity, params, _return, body},
         counter,
         file,
         offsets
       ) do
    param_nodes =
      params
      |> Enum.map(&translate_param(&1, counter, file, offsets))
      |> Enum.map(&mark_as_definitions/1)

    body_nodes = translate_body(body, counter, file, offsets)

    func_span = span(offsets, loc, file)

    clause = %Node{
      id: Counter.next(counter),
      type: :clause,
      meta: %{kind: :function_clause},
      children: param_nodes ++ body_nodes,
      source_span: func_span
    }

    %Node{
      id: Counter.next(counter),
      type: :function_def,
      meta: %{
        name: String.to_atom(name),
        arity: length(params),
        publicity: publicity
      },
      children: [clause],
      source_span: func_span
    }
  end

  defp translate_param({:function_parameter, _label, name_info, _type}, counter, _file, _offsets) do
    name =
      case name_info do
        {:named, n} -> String.to_atom(n)
        {:discarded, n} -> String.to_atom("_" <> n)
      end

    %Node{
      id: Counter.next(counter),
      type: :var,
      meta: %{name: name, binding_role: :definition},
      children: [],
      source_span: nil
    }
  end

  defp translate_body(stmts, counter, file, offsets) when is_list(stmts) do
    Enum.map(stmts, &translate_statement(&1, counter, file, offsets))
  end

  # ── Statement translation ──

  defp translate_statement({:expression, expr}, counter, file, offsets) do
    translate_expr(expr, counter, file, offsets)
  end

  defp translate_statement(
         {:assignment, loc, _kind, pattern, _annotation, value},
         counter,
         file,
         offsets
       ) do
    pat = translate_pattern(pattern, counter, file, offsets) |> mark_as_definitions()
    val = translate_expr(value, counter, file, offsets)

    %Node{
      id: Counter.next(counter),
      type: :match,
      meta: %{},
      children: [pat, val],
      source_span: span(offsets, loc, file)
    }
  end

  defp translate_statement({:use, _loc, _patterns, func}, counter, file, offsets) do
    translate_expr(func, counter, file, offsets)
  end

  defp translate_statement({:assert, _loc, expr, _msg}, counter, file, offsets) do
    translate_expr(expr, counter, file, offsets)
  end

  # ── Expression translation ──

  defp translate_expr({:int, loc, val}, counter, file, offsets) do
    %Node{
      id: Counter.next(counter),
      type: :literal,
      meta: %{value: parse_int(val)},
      children: [],
      source_span: span(offsets, loc, file)
    }
  end

  defp translate_expr({:float, loc, val}, counter, file, offsets) do
    %Node{
      id: Counter.next(counter),
      type: :literal,
      meta: %{value: parse_float(val)},
      children: [],
      source_span: span(offsets, loc, file)
    }
  end

  defp translate_expr({:string, loc, val}, counter, file, offsets) do
    %Node{
      id: Counter.next(counter),
      type: :literal,
      meta: %{value: val},
      children: [],
      source_span: span(offsets, loc, file)
    }
  end

  defp translate_expr({:variable, loc, name}, counter, file, offsets) do
    %Node{
      id: Counter.next(counter),
      type: :var,
      meta: %{name: String.to_atom(name)},
      children: [],
      source_span: span(offsets, loc, file)
    }
  end

  defp translate_expr({:negate_int, loc, expr}, counter, file, offsets) do
    inner = translate_expr(expr, counter, file, offsets)

    %Node{
      id: Counter.next(counter),
      type: :unary_op,
      meta: %{operator: :-},
      children: [inner],
      source_span: span(offsets, loc, file)
    }
  end

  defp translate_expr({:negate_bool, loc, expr}, counter, file, offsets) do
    inner = translate_expr(expr, counter, file, offsets)

    %Node{
      id: Counter.next(counter),
      type: :unary_op,
      meta: %{operator: :!},
      children: [inner],
      source_span: span(offsets, loc, file)
    }
  end

  defp translate_expr({:binary_operator, loc, op, left, right}, counter, file, offsets) do
    l = translate_expr(left, counter, file, offsets)
    r = translate_expr(right, counter, file, offsets)

    case op do
      :pipe ->
        %Node{
          id: Counter.next(counter),
          type: :call,
          meta: %{operator: :pipe, kind: :pipe},
          children: [r, l],
          source_span: span(offsets, loc, file)
        }

      _ ->
        %Node{
          id: Counter.next(counter),
          type: :binary_op,
          meta: %{operator: op},
          children: [l, r],
          source_span: span(offsets, loc, file)
        }
    end
  end

  defp translate_expr(
         {:call, loc, func_expr, args},
         counter,
         file,
         offsets
       ) do
    _func_node = translate_expr(func_expr, counter, file, offsets)

    arg_nodes =
      Enum.map(args, fn
        {:unlabelled_field, expr} ->
          translate_expr(expr, counter, file, offsets)

        {:labelled_field, _label, _span, expr} ->
          translate_expr(expr, counter, file, offsets)

        {:shorthand_field, name, loc} ->
          %Node{
            id: Counter.next(counter),
            type: :var,
            meta: %{name: String.to_atom(name)},
            children: [],
            source_span: span(offsets, loc, file)
          }
      end)

    {module, function} = extract_call_info(func_expr)

    %Node{
      id: Counter.next(counter),
      type: :call,
      meta: %{
        module: module,
        function: function,
        arity: length(arg_nodes),
        kind: if(module, do: :remote, else: :local)
      },
      children: arg_nodes,
      source_span: span(offsets, loc, file)
    }
  end

  defp translate_expr({:field_access, loc, container, label}, counter, file, offsets) do
    cont = translate_expr(container, counter, file, offsets)

    %Node{
      id: Counter.next(counter),
      type: :call,
      meta: %{function: String.to_atom(label), kind: :field_access},
      children: [cont],
      source_span: span(offsets, loc, file)
    }
  end

  defp translate_expr({:tuple, loc, elements}, counter, file, offsets) do
    children = Enum.map(elements, &translate_expr(&1, counter, file, offsets))

    %Node{
      id: Counter.next(counter),
      type: :tuple,
      meta: %{},
      children: children,
      source_span: span(offsets, loc, file)
    }
  end

  defp translate_expr({:list, loc, elements, rest}, counter, file, offsets) do
    el_nodes = Enum.map(elements, &translate_expr(&1, counter, file, offsets))

    rest_node =
      case rest do
        {:some, r} -> [translate_expr(r, counter, file, offsets)]
        :none -> []
      end

    %Node{
      id: Counter.next(counter),
      type: :list,
      meta: %{},
      children: el_nodes ++ rest_node,
      source_span: span(offsets, loc, file)
    }
  end

  defp translate_expr({:case, loc, subjects, clauses}, counter, file, offsets) do
    subject_nodes = Enum.map(subjects, &translate_expr(&1, counter, file, offsets))

    clause_nodes =
      clauses
      |> Enum.with_index()
      |> Enum.map(fn {{:clause, patterns, guard, body}, idx} ->
        pat_nodes =
          patterns
          |> List.flatten()
          |> Enum.map(&translate_pattern(&1, counter, file, offsets))
          |> Enum.map(&mark_as_definitions/1)

        guard_node =
          case guard do
            {:some, g} -> [translate_expr(g, counter, file, offsets)]
            :none -> []
          end

        body_node = translate_expr(body, counter, file, offsets)

        first_pat = List.first(patterns) |> List.wrap() |> List.first()
        clause_loc = if first_pat, do: elem(first_pat, 1), else: loc

        %Node{
          id: Counter.next(counter),
          type: :clause,
          meta: %{index: idx, kind: :case_clause},
          children: pat_nodes ++ guard_node ++ [body_node],
          source_span: span(offsets, clause_loc, file)
        }
      end)

    %Node{
      id: Counter.next(counter),
      type: :case,
      meta: %{},
      children: subject_nodes ++ clause_nodes,
      source_span: span(offsets, loc, file)
    }
  end

  defp translate_expr({:block, loc, stmts}, counter, file, offsets) do
    children = translate_body(stmts, counter, file, offsets)

    %Node{
      id: Counter.next(counter),
      type: :block,
      meta: %{},
      children: children,
      source_span: span(offsets, loc, file)
    }
  end

  defp translate_expr({:fn, loc, params, _return, body}, counter, file, offsets) do
    param_nodes =
      Enum.map(params, fn {:fn_parameter, name_info, _type} ->
        name =
          case name_info do
            {:named, n} -> String.to_atom(n)
            {:discarded, n} -> String.to_atom("_" <> n)
          end

        %Node{
          id: Counter.next(counter),
          type: :var,
          meta: %{name: name, binding_role: :definition},
          children: [],
          source_span: nil
        }
      end)
      |> Enum.map(&mark_as_definitions/1)

    body_nodes = translate_body(body, counter, file, offsets)

    fn_span = span(offsets, loc, file)

    clause = %Node{
      id: Counter.next(counter),
      type: :clause,
      meta: %{index: 0, kind: :fn_clause},
      children: param_nodes ++ body_nodes,
      source_span: fn_span
    }

    %Node{
      id: Counter.next(counter),
      type: :fn,
      meta: %{},
      children: [clause],
      source_span: fn_span
    }
  end

  defp translate_expr({:record_update, loc, _mod, _ctor, record, fields}, counter, file, offsets) do
    rec = translate_expr(record, counter, file, offsets)

    field_nodes =
      Enum.flat_map(fields, fn
        {:record_update_field, _label, {:some, val}} ->
          [translate_expr(val, counter, file, offsets)]

        {:record_update_field, _label, :none} ->
          []

        {:record_update_field, _l, _label, val} ->
          [translate_expr(val, counter, file, offsets)]
      end)

    %Node{
      id: Counter.next(counter),
      type: :map,
      meta: %{kind: :update},
      children: [rec | field_nodes],
      source_span: span(offsets, loc, file)
    }
  end

  defp translate_expr({:tuple_index, loc, tuple, index}, counter, file, offsets) do
    t = translate_expr(tuple, counter, file, offsets)

    %Node{
      id: Counter.next(counter),
      type: :call,
      meta: %{function: :element, kind: :tuple_index, index: index},
      children: [t],
      source_span: span(offsets, loc, file)
    }
  end

  defp translate_expr(
         {:fn_capture, _loc, _label, func, _before, _after_args},
         counter,
         file,
         offsets
       ) do
    translate_expr(func, counter, file, offsets)
  end

  defp translate_expr({:panic, loc, _msg}, counter, file, offsets) do
    %Node{
      id: Counter.next(counter),
      type: :call,
      meta: %{function: :panic, kind: :local},
      children: [],
      source_span: span(offsets, loc, file)
    }
  end

  defp translate_expr({:todo, loc, _msg}, counter, file, offsets) do
    %Node{
      id: Counter.next(counter),
      type: :call,
      meta: %{function: :todo, kind: :local},
      children: [],
      source_span: span(offsets, loc, file)
    }
  end

  defp translate_expr({:echo, loc, expr, _msg}, counter, file, offsets) do
    case expr do
      {:some, e} ->
        translate_expr(e, counter, file, offsets)

      :none ->
        %Node{
          id: Counter.next(counter),
          type: :call,
          meta: %{function: :echo, kind: :local},
          children: [],
          source_span: span(offsets, loc, file)
        }
    end
  end

  defp translate_expr({:bit_string, loc, _segments}, counter, file, offsets) do
    %Node{
      id: Counter.next(counter),
      type: :literal,
      meta: %{kind: :bit_string},
      children: [],
      source_span: span(offsets, loc, file)
    }
  end

  defp translate_expr(_other, counter, _file, _offsets) do
    %Node{
      id: Counter.next(counter),
      type: :literal,
      meta: %{value: :unknown, raw: nil},
      children: [],
      source_span: nil
    }
  end

  # ── Pattern translation ──

  defp translate_pattern({:pattern_variable, loc, name}, counter, file, offsets) do
    %Node{
      id: Counter.next(counter),
      type: :var,
      meta: %{name: String.to_atom(name), binding_role: :definition},
      children: [],
      source_span: span(offsets, loc, file)
    }
  end

  defp translate_pattern({:pattern_discard, loc, name}, counter, file, offsets) do
    %Node{
      id: Counter.next(counter),
      type: :var,
      meta: %{name: String.to_atom("_" <> name), binding_role: :definition},
      children: [],
      source_span: span(offsets, loc, file)
    }
  end

  defp translate_pattern({:pattern_int, loc, val}, counter, file, offsets) do
    %Node{
      id: Counter.next(counter),
      type: :literal,
      meta: %{value: parse_int(val)},
      children: [],
      source_span: span(offsets, loc, file)
    }
  end

  defp translate_pattern({:pattern_float, loc, val}, counter, file, offsets) do
    %Node{
      id: Counter.next(counter),
      type: :literal,
      meta: %{value: parse_float(val)},
      children: [],
      source_span: span(offsets, loc, file)
    }
  end

  defp translate_pattern({:pattern_string, loc, val}, counter, file, offsets) do
    %Node{
      id: Counter.next(counter),
      type: :literal,
      meta: %{value: val},
      children: [],
      source_span: span(offsets, loc, file)
    }
  end

  defp translate_pattern({:pattern_tuple, loc, elements}, counter, file, offsets) do
    children = Enum.map(elements, &translate_pattern(&1, counter, file, offsets))

    %Node{
      id: Counter.next(counter),
      type: :tuple,
      meta: %{},
      children: children,
      source_span: span(offsets, loc, file)
    }
  end

  defp translate_pattern({:pattern_list, loc, elements, tail}, counter, file, offsets) do
    el_nodes = Enum.map(elements, &translate_pattern(&1, counter, file, offsets))

    tail_node =
      case tail do
        {:some, t} -> [translate_pattern(t, counter, file, offsets)]
        :none -> []
      end

    %Node{
      id: Counter.next(counter),
      type: :list,
      meta: %{},
      children: el_nodes ++ tail_node,
      source_span: span(offsets, loc, file)
    }
  end

  defp translate_pattern(
         {:pattern_variant, loc, module, constructor, fields, _spread},
         counter,
         file,
         offsets
       ) do
    field_nodes =
      Enum.map(fields, fn
        {:unlabelled_field, pat} ->
          translate_pattern(pat, counter, file, offsets)

        {:labelled_field, _label, _span, pat} ->
          translate_pattern(pat, counter, file, offsets)

        {:shorthand_field, name, loc} ->
          %Node{
            id: Counter.next(counter),
            type: :var,
            meta: %{name: String.to_atom(name), binding_role: :definition},
            children: [],
            source_span: span(offsets, loc, file)
          }
      end)

    %Node{
      id: Counter.next(counter),
      type: :struct,
      meta: %{
        name: String.to_atom(constructor),
        module: if(is_binary(module), do: String.to_atom(module))
      },
      children: field_nodes,
      source_span: span(offsets, loc, file)
    }
  end

  defp translate_pattern({:pattern_assignment, loc, pattern, name}, counter, file, offsets) do
    inner = translate_pattern(pattern, counter, file, offsets)
    pat_span = span(offsets, loc, file)

    var = %Node{
      id: Counter.next(counter),
      type: :var,
      meta: %{name: String.to_atom(name), binding_role: :definition},
      children: [],
      source_span: pat_span
    }

    %Node{
      id: Counter.next(counter),
      type: :match,
      meta: %{},
      children: [inner, var],
      source_span: pat_span
    }
  end

  defp translate_pattern(
         {:pattern_concatenate, loc, _prefix, _prefix_name, _rest},
         counter,
         file,
         offsets
       ) do
    %Node{
      id: Counter.next(counter),
      type: :literal,
      meta: %{kind: :string_prefix},
      children: [],
      source_span: span(offsets, loc, file)
    }
  end

  defp translate_pattern(_other, counter, _file, _offsets) do
    %Node{
      id: Counter.next(counter),
      type: :literal,
      meta: %{value: :unknown_pattern},
      children: [],
      source_span: nil
    }
  end

  # ── Helpers ──

  defp extract_call_info({:field_access, _, {:variable, _, mod}, func}) do
    {String.to_atom(mod), String.to_atom(func)}
  end

  defp extract_call_info({:variable, _, name}), do: {nil, String.to_atom(name)}
  defp extract_call_info(_), do: {nil, :unknown}

  defp parse_int(s) do
    s |> String.replace("_", "") |> String.to_integer()
  rescue
    _ -> 0
  end

  defp parse_float(s) do
    s |> String.replace("_", "") |> String.to_float()
  rescue
    _ -> 0.0
  end
end
