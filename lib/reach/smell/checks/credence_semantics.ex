defmodule Reach.Smell.Checks.CredenceSemantics do
  @moduledoc "Detects semantic anti-patterns inspired by Credence rules."

  @behaviour Reach.Smell.Check

  alias Reach.Smell.Finding

  @logger_functions ~w(debug info notice warning error critical alert emergency log)a
  @sentinels [-1, :not_found, :missing, :error]

  @impl true
  def run(project) do
    files = module_files(project)

    Enum.flat_map(files, &scan_file/1) ++ missing_logger_requires(project)
  end

  defp module_files(project) do
    project.nodes
    |> Enum.map(fn {_, node} -> node.source_span && node.source_span[:file] end)
    |> Enum.filter(&(&1 && File.regular?(&1)))
    |> Enum.uniq()
  end

  defp scan_file(file) do
    ast = file |> File.read!() |> Code.string_to_quoted!()

    [
      fn -> map_has_key_then_get(ast, file) end,
      fn -> map_get_sentinel(ast, file) end,
      fn -> length_based_indexing(ast, file) end,
      fn -> invalid_keyword_access(ast, file) end
    ]
    |> Enum.flat_map(fn scan -> scan.() end)
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
      finding(
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
          finding(
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
          finding(
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
          finding(
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
        finding(
          :bug_risk,
          "Keyword keys must be atoms; integer key access is not list indexing",
          file,
          meta
        )

      {{:., meta, [{:__aliases__, _, [:Keyword]}, fun]}, _, [_opts, key]}
      when fun in [:fetch, :fetch!] and is_integer(key) ->
        finding(
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
          [] -> {node, acc}
          values when is_list(values) -> {node, values ++ acc}
          value -> {node, [value | acc]}
        end
      end)

    Enum.reverse(findings)
  end

  defp finding(kind, message, file, meta) do
    line = meta[:line] || 0
    Finding.new(kind: kind, message: message, location: "#{file}:#{line}")
  end
end
