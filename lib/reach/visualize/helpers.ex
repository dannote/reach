defmodule Reach.Visualize.Helpers do
  @moduledoc false

  alias Reach.Visualize

  # ── Source helpers ──

  def highlight_line(file, line) when is_binary(file) and is_integer(line) do
    case read_line(file, line) do
      nil -> nil
      text -> Visualize.highlight_source(String.trim_leading(text))
    end
  end

  def highlight_line(_, _), do: nil

  def highlight_lines(file, from, to) when is_binary(file) do
    case cached_file_lines(file) do
      nil ->
        nil

      lines ->
        lines
        |> Enum.slice((from - 1)..max(from - 1, to - 1))
        |> dedent()
        |> Enum.join("\n")
        |> Visualize.highlight_source()
    end
  end

  def highlight_lines(_, _, _), do: nil

  def dedent(lines) do
    min_indent =
      lines
      |> Enum.reject(&(String.trim(&1) == ""))
      |> Enum.map(fn line -> byte_size(line) - byte_size(String.trim_leading(line)) end)
      |> Enum.min(fn -> 0 end)

    Enum.map(lines, fn line -> String.slice(line, min_indent, byte_size(line)) end)
  end

  def read_line(file, line) do
    case cached_file_lines(file) do
      nil -> nil
      lines -> Enum.at(lines, line - 1)
    end
  end

  def cached_file_lines(file) do
    if source_file?(file), do: do_cached_file_lines(file), else: nil
  end

  defp do_cached_file_lines(file) do
    cache_key = {:reach_file_lines, file}

    case Process.get(cache_key) do
      nil ->
        with {:ok, content} <- File.read(file),
             true <- String.valid?(content) do
          lines = String.split(content, "\n")
          Process.put(cache_key, lines)
          lines
        else
          _ -> nil
        end

      lines ->
        lines
    end
  end

  # ── IR helpers ──

  def clause_pattern(clause) do
    clause.children
    |> Enum.take_while(fn c ->
      c.meta[:binding_role] == :definition or
        c.type in [:literal, :tuple, :map, :list, :struct, :var]
    end)
    |> Enum.map_join(", ", &ir_label/1)
    |> case do
      "" -> "_"
      s -> s
    end
  end

  def ir_label(%{type: :literal, meta: %{value: val}}), do: inspect(val)
  def ir_label(%{type: :var, meta: %{name: name}}), do: to_string(name)
  def ir_label(%{type: :tuple}), do: "{...}"
  def ir_label(%{type: :map}), do: "%{...}"
  def ir_label(%{type: :binary_op, meta: %{operator: op}}), do: to_string(op)
  def ir_label(%{type: :unary_op, meta: %{operator: op}}), do: to_string(op)
  def ir_label(%{type: :pin}), do: "^"
  def ir_label(%{type: :guard}), do: "guard"
  def ir_label(%{type: :cons}), do: "[head | tail]"
  def ir_label(%{type: :generator}), do: "<-"
  def ir_label(%{type: :filter}), do: "filter"
  def ir_label(%{type: :module_def, meta: %{name: name}}), do: "defmodule #{inspect(name)}"
  def ir_label(%{type: type}), do: to_string(type)

  def render_pattern(%{type: :literal, meta: %{value: val}}), do: inspect(val)
  def render_pattern(%{type: :var, meta: %{name: name}}), do: to_string(name)

  def render_pattern(%{type: :tuple, children: children}) do
    inner = Enum.map_join(children, ", ", &render_pattern/1)
    "{#{inner}}"
  end

  def render_pattern(%{type: :map, children: children}) do
    pairs = Enum.map_join(children, ", ", &render_map_field/1)
    "%{#{pairs}}"
  end

  def render_pattern(%{type: :list, children: children}) do
    inner = Enum.map_join(children, ", ", &render_pattern/1)
    "[#{inner}]"
  end

  def render_pattern(%{type: :struct, children: children, meta: meta}) do
    name = if meta[:name], do: inspect(meta[:name]), else: ""
    fields = Enum.map_join(children, ", ", &render_map_field/1)
    "%#{name}{#{fields}}"
  end

  def render_pattern(%{type: :pin, children: [inner]}), do: "^#{render_pattern(inner)}"
  def render_pattern(%{type: :pin}), do: "^_"

  def render_pattern(%{type: :binary_op, meta: %{operator: op}, children: [left, right]}) do
    "#{render_pattern(left)} #{op} #{render_pattern(right)}"
  end

  def render_pattern(%{type: :unary_op, meta: %{operator: op}, children: [inner]}) do
    "#{op}#{render_pattern(inner)}"
  end

  def render_pattern(%{type: :cons, children: [head, tail]}) do
    "[#{render_pattern(head)} | #{render_pattern(tail)}]"
  end

  def render_pattern(%{type: :guard, children: [inner]}), do: render_pattern(inner)
  def render_pattern(%{type: :guard}), do: "true"

  def render_pattern(%{type: :generator, children: [pattern, _expr]}) do
    "#{render_pattern(pattern)} <- ..."
  end

  def render_pattern(%{type: :filter, children: [inner]}), do: render_pattern(inner)

  def render_pattern(%{type: :module_def, meta: %{name: name}}) do
    "defmodule #{inspect(name)}"
  end

  def render_pattern(%{type: type}), do: to_string(type)

  defp render_map_field(%{
         type: :map_field,
         children: [%{type: :literal, meta: %{value: key}}, val]
       }) do
    "#{key}: #{render_pattern(val)}"
  end

  defp render_map_field(%{type: :map_field, children: [key, _val]}) do
    "#{render_pattern(key)}: ..."
  end

  defp render_map_field(node), do: render_pattern(node)

  def extract_clause_source(func, clause, all_clauses, file) do
    clause_start = span_field(clause, :start_line) || min_child_line(clause)

    with true <- is_binary(file) and is_integer(clause_start),
         end_line <- clause_end_line(func, clause_start, all_clauses, file),
         true <- is_integer(end_line) and end_line >= clause_start do
      case cached_file_lines(file) do
        nil ->
          nil

        lines ->
          lines
          |> Enum.slice((clause_start - 1)..(end_line - 1))
          |> dedent()
          |> Enum.join("\n")
          |> Visualize.format_source()
      end
    else
      _ -> nil
    end
  end

  def min_line_in_subtree(node) do
    line = span_field(node, :start_line)
    child_lines = Enum.flat_map(node.children, &collect_lines/1)
    all = if line, do: [line | child_lines], else: child_lines
    Enum.min(all, fn -> nil end)
  end

  defp min_child_line(node) do
    node.children
    |> Enum.flat_map(&collect_lines/1)
    |> Enum.min(fn -> nil end)
  end

  defp collect_lines(node) do
    line = span_field(node, :start_line)
    child_lines = Enum.flat_map(node.children, &collect_lines/1)
    if line, do: [line | child_lines], else: child_lines
  end

  def clause_end_line(func, clause_start, all_clauses, file) do
    next_start =
      all_clauses
      |> Enum.map(&(span_field(&1, :start_line) || min_child_line(&1) || 0))
      |> Enum.filter(&(&1 > clause_start))
      |> Enum.min(fn -> nil end)

    (next_start && next_start - 1) || func_end_line(func, file)
  end

  def func_end_line(func, file) do
    case span_field(func, :end_line) do
      end_line when is_integer(end_line) ->
        end_line

      _ ->
        if file, do: Visualize.ensure_def_cache(file)
        start = span_field(func, :start_line)
        fallback = file_line_count(file) || (start || 1) + 50
        line_map = Process.get(:reach_def_end_cache, %{}) |> Map.get(file, %{})
        Map.get(line_map, start) || find_nearest_end(line_map, start) || fallback
    end
  end

  defp find_nearest_end(line_map, start) when is_integer(start) do
    line_map
    |> Map.keys()
    |> Enum.filter(&(&1 <= start))
    |> Enum.max(fn -> nil end)
    |> then(fn nearest -> if nearest, do: Map.get(line_map, nearest) end)
  end

  defp find_nearest_end(_, _), do: nil

  def span_field(%{source_span: %{} = span}, field), do: Map.get(span, field)
  def span_field(_, _), do: nil

  defp file_line_count(nil), do: nil

  defp file_line_count(file) do
    case cached_file_lines(file) do
      nil -> nil
      lines -> length(lines)
    end
  end

  @source_extensions [".ex", ".exs", ".erl", ".hrl", ".gleam"]

  @doc false
  def source_file?(nil), do: false
  def source_file?(file), do: Path.extname(file) in @source_extensions
end
