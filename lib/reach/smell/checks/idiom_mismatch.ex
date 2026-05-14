defmodule Reach.Smell.Checks.IdiomMismatch do
  @moduledoc "Detects non-idiomatic patterns such as guard equality and update-then-fetch."

  use Reach.Smell.Check

  @logger_functions ~w(debug info notice warning error critical alert emergency log)a
  @sentinels [-1, :not_found, :missing, :error]

  @impl true
  def run(project) do
    function_findings =
      project
      |> Helpers.function_defs()
      |> Enum.flat_map(&findings/1)

    file_findings =
      project
      |> module_files()
      |> Enum.flat_map(&scan_file/1)

    function_findings ++ file_findings ++ missing_logger_requires(project)
  end

  defp findings(function) do
    guard_equality_findings(function) ++
      map_update_then_fetch(function) ++
      redundant_negated_guard(function) ++
      destructure_reconstruct(function) ++
      length_in_guard(function)
  end

  defp guard_equality_findings(function) do
    function.children
    |> Enum.filter(&(&1.type == :clause and &1.meta[:kind] == :function_clause))
    |> Enum.flat_map(&guard_equalities(&1, function))
  end

  defp guard_equalities(clause, _function) do
    clause
    |> IR.all_nodes()
    |> Enum.filter(&guard_with_literal_equality?/1)
    |> Enum.flat_map(fn guard ->
      guard
      |> IR.all_nodes()
      |> Enum.filter(fn n ->
        n.type == :binary_op and n.meta[:operator] == :== and
          has_literal_and_var?(n.children) and n.source_span
      end)
      |> Enum.map(fn eq_node ->
        finding(
          :suboptimal,
          "guard compares parameter to literal with ==; use pattern matching in the function head",
          eq_node
        )
      end)
    end)
  end

  defp guard_with_literal_equality?(%{type: :guard} = guard) do
    guard
    |> IR.all_nodes()
    |> Enum.any?(fn node ->
      node.type == :binary_op and node.meta[:operator] == :== and
        has_literal_and_var?(node.children)
    end)
  end

  defp guard_with_literal_equality?(_), do: false

  defp has_literal_and_var?([left, right]) do
    (literal?(left) and var?(right)) or (var?(left) and literal?(right))
  end

  defp has_literal_and_var?(_), do: false

  defp literal?(%{type: :literal, meta: %{value: v}})
       when is_atom(v) or is_integer(v) or is_binary(v), do: true

  defp literal?(_), do: false

  defp var?(%{type: :var}), do: true
  defp var?(_), do: false

  defp map_update_then_fetch(function) do
    Helpers.statement_pairs(function)
    |> Enum.flat_map(fn {first, second} ->
      update_var = map_update_binding(first)
      fetch_var = map_fetch_on(second)

      if update_var && fetch_var && update_var == fetch_var do
        [
          finding(
            :suboptimal,
            "Map.update then Map.get/fetch on same variable traverses twice; compute value first with Map.get, then Map.put",
            second
          )
        ]
      else
        []
      end
    end)
  end

  defp map_update_binding(%{type: :match, children: [%{type: :var, meta: %{name: var}}, call]}) do
    if call.type == :call and call.meta[:module] == Map and
         call.meta[:function] in [:update, :update!] do
      var
    end
  end

  defp map_update_binding(_), do: nil

  defp map_fetch_on(node) do
    node
    |> IR.all_nodes()
    |> Enum.find_value(&map_fetch_var/1)
  end

  defp map_fetch_var(%{
         type: :call,
         meta: %{module: Map, function: f},
         children: [%{type: :var, meta: %{name: var}} | _]
       })
       when f in [:get, :fetch, :fetch!],
       do: var

  defp map_fetch_var(_), do: nil

  # --- Redundant negated guard ---

  defp redundant_negated_guard(function) do
    clauses =
      function.children
      |> Enum.filter(&(&1.type == :clause and &1.meta[:kind] == :function_clause))

    clauses
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.flat_map(fn [prev, curr] -> check_guard_pair(prev, curr, function) end)
  end

  defp check_guard_pair(prev_clause, curr_clause, function) do
    with {:ok, :==, prev_left, prev_right} <- extract_guard_comparison(prev_clause),
         {:ok, :!=, curr_left, curr_right} <- extract_guard_comparison(curr_clause),
         true <- same_var_name?(prev_left, curr_left) and same_var_name?(prev_right, curr_right) do
      [
        finding(
          :suboptimal,
          "redundant negated guard; the preceding clause already handles the complementary case",
          (curr_clause.source_span && curr_clause) || function
        )
      ]
    else
      _ -> []
    end
  end

  defp extract_guard_comparison(clause) do
    clause.children
    |> Enum.find(&(&1.type == :guard))
    |> guard_to_comparison()
  end

  defp guard_to_comparison(nil), do: :error

  defp guard_to_comparison(guard) do
    guard
    |> IR.all_nodes()
    |> Enum.find(&(&1.type == :binary_op and &1.meta[:operator] in [:==, :!=, :===, :!==]))
    |> case do
      %{meta: %{operator: op}, children: [left, right]} ->
        normalized_op = if op in [:==, :===], do: :==, else: :!=
        {:ok, normalized_op, left, right}

      _ ->
        :error
    end
  end

  defp same_var_name?(%{type: :var, meta: %{name: a}}, %{type: :var, meta: %{name: b}}),
    do: a == b

  defp same_var_name?(_, _), do: false

  # --- Destructure then reconstruct ---

  defp destructure_reconstruct(function) do
    all_nodes = IR.all_nodes(function)

    all_nodes
    |> Enum.filter(&(&1.type == :clause and &1.meta[:kind] in [:case_clause, :function_clause]))
    |> Enum.flat_map(&check_clause_destructure/1)
  end

  defp check_clause_destructure(clause) do
    patterns = Enum.filter(clause.children, &(&1.type == :list))

    body =
      Enum.reject(
        clause.children,
        &(&1.type == :list or &1.type == :guard or &1.meta[:binding_role] == :definition)
      )

    Enum.flat_map(patterns, fn pattern ->
      var_names = extract_list_var_names(pattern)

      if length(var_names) >= 3 and body_rebuilds_list?(body, var_names) do
        [
          finding(
            :suboptimal,
            "list destructured into [#{Enum.join(var_names, ", ")}] then reassembled; bind as a whole with `= name`",
            (pattern.source_span && pattern) || clause
          )
        ]
      else
        []
      end
    end)
  end

  defp extract_list_var_names(%{type: :list, children: children}) do
    names =
      Enum.map(children, fn
        %{type: :var, meta: %{name: name}} ->
          str = Atom.to_string(name)
          if String.starts_with?(str, "_"), do: nil, else: name

        _ ->
          nil
      end)

    if Enum.any?(names, &is_nil/1), do: [], else: names
  end

  defp body_rebuilds_list?(body, target_names) do
    body
    |> Enum.flat_map(&IR.all_nodes/1)
    |> Enum.any?(fn
      %{type: :list, children: children} ->
        extract_list_var_names(%{type: :list, children: children}) == target_names

      _ ->
        false
    end)
  end

  # --- Length in guard ---

  defp length_in_guard(function) do
    function.children
    |> Enum.filter(&function_clause?/1)
    |> Enum.flat_map(&clause_length_guard_findings(&1, function))
  end

  defp function_clause?(%{type: :clause, meta: %{kind: :function_clause}}), do: true
  defp function_clause?(_), do: false

  defp clause_length_guard_findings(clause, function) do
    clause.children
    |> Enum.filter(&(&1.type == :guard))
    |> Enum.flat_map(&guard_length_findings(&1, function))
  end

  defp guard_length_findings(guard, function) do
    guard
    |> IR.all_nodes()
    |> Enum.filter(&length_comparison?/1)
    |> Enum.map(&length_guard_finding(&1, function))
  end

  defp length_guard_finding(node, function) do
    finding(
      :suboptimal,
      "length/1 in guard is O(n); use list pattern matching instead",
      (node.source_span && node) || function
    )
  end

  defp length_comparison?(%{type: :binary_op, meta: %{operator: op}, children: [left, right]})
       when op in [:==, :>, :>=] do
    length_call?(left) and small_literal?(right)
  end

  defp length_comparison?(%{type: :binary_op, meta: %{operator: op}, children: [left, right]})
       when op in [:==, :<, :<=] do
    small_literal?(left) and length_call?(right)
  end

  defp length_comparison?(_), do: false

  defp length_call?(%{type: :call, meta: %{function: :length, kind: :local}}), do: true
  defp length_call?(_), do: false

  defp small_literal?(%{type: :literal, meta: %{value: n}})
       when is_integer(n) and n >= 0 and n <= 5,
       do: true

  defp small_literal?(_), do: false

  # --- File-level semantic idioms ---

  defp module_files(project) do
    project.nodes
    |> Enum.map(fn {_, node} -> node.source_span && node.source_span[:file] end)
    |> Enum.filter(&(&1 && File.regular?(&1)))
    |> Enum.uniq()
  end

  defp scan_file(file) do
    ast = file |> File.read!() |> Code.string_to_quoted!()

    map_has_key_then_get(ast, file) ++
      map_get_sentinel(ast, file) ++
      length_based_indexing(ast, file) ++
      invalid_keyword_access(ast, file)
  rescue
    _ -> []
  end

  defp missing_logger_requires(project) do
    project.nodes
    |> Enum.map(fn {_id, node} -> node end)
    |> Enum.filter(fn node ->
      node.type == :call and node.meta[:module] == Logger and
        node.meta[:function] in @logger_functions and node.source_span
    end)
    |> Enum.reject(fn node ->
      node.source_span[:file]
      |> File.read!()
      |> logger_available?()
    end)
    |> Enum.map(fn node ->
      file_finding(
        :missing_require,
        "Logger macros are used without `require Logger` in the module",
        node.source_span[:file],
        line: node.source_span[:start_line]
      )
    end)
  end

  defp logger_available?(source) do
    String.contains?(source, "require Logger") or String.contains?(source, "import Logger")
  end

  defp map_has_key_then_get(ast, file) do
    ast
    |> collect_nodes(fn
      {:if, meta, [condition, clauses]} ->
        with {:ok, map, key} <- map_has_key_call(condition),
             true <- subtree_has_map_read?(Keyword.get(clauses, :do), map, key) do
          file_finding(
            :suboptimal,
            "Map.has_key?/2 followed by Map.get/fetch performs two lookups; use Map.fetch/2 or pattern matching",
            file,
            meta
          )
        else
          _ -> nil
        end

      _ ->
        nil
    end)
  end

  defp map_has_key_call({{:., _, [{:__aliases__, _, [:Map]}, :has_key?]}, _, [map, key]}),
    do: {:ok, map, key}

  defp map_has_key_call(_), do: :error

  defp subtree_has_map_read?(nil, _map, _key), do: false

  defp subtree_has_map_read?(ast, map, key) do
    {_ast, found?} =
      Macro.prewalk(ast, false, fn
        {{:., _, [{:__aliases__, _, [:Map]}, fun]}, _, [read_map, read_key | _]} = node, _acc
        when fun in [:get, :fetch, :fetch!] ->
          {node,
           Macro.to_string(read_map) == Macro.to_string(map) and
             Macro.to_string(read_key) == Macro.to_string(key)}

        node, acc ->
          {node, acc}
      end)

    found?
  end

  defp map_get_sentinel(ast, file) do
    ast
    |> block_statements()
    |> Enum.flat_map(&sentinel_findings_in_statements(&1, file))
  end

  defp sentinel_findings_in_statements(statements, file) do
    statements
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.flat_map(fn [statement, next] ->
      with {:ok, var, sentinel, meta} <- map_get_sentinel_assignment(statement),
           true <- sentinel in @sentinels,
           true <- compares_var_to?(next, var, sentinel) do
        [
          file_finding(
            :sentinel_default,
            "Map.get/3 with a sentinel default leaks Python-style dictionary access; prefer Map.fetch/2, nil, or tagged tuples",
            file,
            meta
          )
        ]
      else
        _ -> []
      end
    end)
  end

  defp map_get_sentinel_assignment({:=, _, [{var, _, context}, call]})
       when is_atom(var) and is_atom(context) do
    case call do
      {{:., meta, [{:__aliases__, _, [:Map]}, :get]}, _, [_map, _key, sentinel_ast]} ->
        {:ok, var, literal_value(sentinel_ast), meta}

      _ ->
        :error
    end
  end

  defp map_get_sentinel_assignment(_), do: :error

  defp compares_var_to?(ast, var, sentinel) do
    {_ast, found?} =
      Macro.prewalk(ast, false, fn
        {op, _, [{^var, _, ctx}, right]} = node, _acc
        when op in [:==, :!=, :===, :!==] and is_atom(ctx) ->
          {node, literal_value(right) == sentinel}

        {op, _, [left, {^var, _, ctx}]} = node, _acc
        when op in [:==, :!=, :===, :!==] and is_atom(ctx) ->
          {node, literal_value(left) == sentinel}

        node, acc ->
          {node, acc}
      end)

    found?
  end

  defp length_based_indexing(ast, file) do
    ast
    |> block_statements()
    |> Enum.flat_map(fn statements ->
      lengths =
        statements
        |> Enum.flat_map(fn
          {:=, _, [{name, _, context}, {:length, _, [list]}]}
          when is_atom(name) and is_atom(context) ->
            [{name, Macro.to_string(list)}]

          _ ->
            []
        end)
        |> Map.new()

      if map_size(lengths) == 0 do
        []
      else
        Enum.flat_map(statements, &length_index_findings(&1, lengths, file))
      end
    end)
  end

  defp length_index_findings(ast, lengths, file) do
    collect_nodes(ast, fn
      {{:., _, [{:__aliases__, _, [:Enum]}, :at]}, meta,
       [list, {:-, _, [{len_var, _, ctx}, offset_ast]}]}
      when is_atom(len_var) and is_atom(ctx) ->
        offset = literal_value(offset_ast)

        if is_integer(offset) and offset > 0 and
             Map.get(lengths, len_var) == Macro.to_string(list) do
          file_finding(
            :suboptimal,
            "length(list) followed by Enum.at(list, length - n) traverses the list repeatedly; use negative indices, pattern matching, or List.last/1",
            file,
            meta
          )
        end

      _ ->
        nil
    end)
  end

  defp invalid_keyword_access(ast, file) do
    collect_nodes(ast, fn
      {{:., meta, [{:__aliases__, _, [:Keyword]}, :get]}, _, [_opts, key, _default]}
      when is_integer(key) ->
        file_finding(
          :bug_risk,
          "Keyword keys must be atoms; integer key access is not list indexing",
          file,
          meta
        )

      {{:., meta, [{:__aliases__, _, [:Keyword]}, fun]}, _, [_opts, key]}
      when fun in [:fetch, :fetch!] and is_integer(key) ->
        file_finding(
          :bug_risk,
          "Keyword keys must be atoms; integer key access is not list indexing",
          file,
          meta
        )

      _ ->
        nil
    end)
  end

  defp literal_value({:-, _, [value]}) when is_integer(value), do: -value

  defp literal_value(value) when is_integer(value) or is_atom(value) or is_binary(value),
    do: value

  defp literal_value(_), do: :__unknown__

  defp block_statements(ast) do
    {_ast, blocks} =
      Macro.prewalk(ast, [], fn
        {:__block__, _, statements} = node, acc when is_list(statements) ->
          {node, [statements | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(blocks)
  end

  defp collect_nodes(ast, fun) do
    {_ast, findings} =
      Macro.prewalk(ast, [], fn node, acc ->
        case fun.(node) do
          nil -> {node, acc}
          value -> {node, [value | acc]}
        end
      end)

    Enum.reverse(findings)
  end

  defp file_finding(kind, message, file, meta) do
    line = meta[:line] || 0
    Finding.new(kind: kind, message: message, location: "#{file}:#{line}")
  end
end
