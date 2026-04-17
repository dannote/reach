defmodule Reach.CLI.Format do
  @moduledoc false

  def render(findings, tool, opts) do
    case opts[:format] || "text" do
      "text" -> render_text(findings, tool)
      "json" -> render_json(findings, tool, opts)
      "oneline" -> render_oneline(findings)
    end
  end

  defp render_text(findings, _tool) do
    IO.write(findings)
  end

  defp render_json(data, tool, opts) do
    output = %{"tool" => tool} |> Map.merge(jsonify(data))
    json = Jason.encode!(output, pretty: Keyword.get(opts, :pretty, true))
    IO.write(json)
    IO.write("\n")
  end

  defp render_oneline(findings) when is_list(findings) do
    Enum.each(findings, &IO.puts/1)
  end

  defp render_oneline(findings) do
    IO.write(findings)
  end

  def jsonify(%Reach.IR.Node{} = node) do
    %{"type" => Atom.to_string(node.type), "id" => node.id}
    |> maybe_add(:name, node.meta[:name])
    |> maybe_add(:module, node.meta[:module])
    |> maybe_add(:function, node.meta[:function])
    |> maybe_add(:location, Reach.CLI.Format.location(node))
  end

  def jsonify(%{__struct__: _} = struct) do
    struct
    |> Map.from_struct()
    |> jsonify()
  end

  def jsonify(%{} = map) do
    Map.new(map, fn {k, v} -> {jsonify_key(k), jsonify(v)} end)
  end

  def jsonify(list) when is_list(list), do: Enum.map(list, &jsonify/1)

  def jsonify({_m, _f, _a} = t) when is_tuple(t) and tuple_size(t) == 3 do
    case t do
      {m, f, a} when is_atom(m) and is_atom(f) and is_number(a) ->
        "#{inspect(m)}.#{f}/#{a}"
      _ ->
        t |> Tuple.to_list() |> jsonify()
    end
  end

  def jsonify(tuple) when is_tuple(tuple), do: jsonify(Tuple.to_list(tuple))
  def jsonify(atom) when is_atom(atom) and not is_nil(atom), do: Atom.to_string(atom)
  def jsonify(nil), do: nil
  def jsonify(other), do: other

  defp jsonify_key(k) when is_binary(k), do: k
  defp jsonify_key(k) when is_atom(k), do: Atom.to_string(k)
  defp jsonify_key(k), do: inspect(k)

  def parse_target(args) do
    case args do
      [raw] ->
        case Regex.run(~r/^([^ ]+)\.(.+)\/(\d+)$/, raw) do
          [_, mod_str, fun_str, arity_str] ->
            mod = String.split(mod_str, ".") |> Enum.map(&String.to_atom/1) |> Module.concat()
            {mod, String.to_atom(fun_str), String.to_integer(arity_str)}

          nil ->
            raw
        end

      [] ->
        nil
    end
  end

  def location(node) do
    case node.source_span do
      %{file: f, start_line: l} -> "#{f}:#{l}"
      _ -> "unknown"
    end
  end

  def func_id_to_string({mod, fun, arity}) when is_atom(mod) and mod != nil do
    "#{inspect(mod)}.#{fun}/#{arity}"
  end

  def func_id_to_string({nil, fun, arity}) do
    "#{fun}/#{arity}"
  end

  def func_id_to_string(other), do: inspect(other)

  def header(title) do
    width = max(String.length(title) + 4, 40)
    "\n#{String.duplicate("─", width)}\n  #{title}\n#{String.duplicate("─", width)}\n"
  end

  def section(title) do
    "\n#{title}\n#{String.duplicate("─", String.length(title))}\n"
  end

  def tree_line(item, last?) do
    prefix = if last?, do: "└── ", else: "├── "
    "#{prefix}#{item}"
  end

  def indent(text, n \\ 2) do
    pad = String.duplicate(" ", n)
    String.split(text, "\n") |> Enum.map_join("\n", &(pad <> &1))
  end

  defp maybe_add(map, _key, nil), do: map
  defp maybe_add(map, key, val), do: Map.put(map, key, jsonify(val))
end
