defmodule Reach.CLI.Format do
  @moduledoc false

  alias Reach.CLI.Project
  alias Reach.IR.Helpers, as: IRHelpers

  # ── Color helpers ──

  defp color?, do: IO.ANSI.enabled?()

  defp c(text, ansi) do
    if color?(), do: [ansi, text, IO.ANSI.reset()] |> IO.iodata_to_binary(), else: text
  end

  def cyan(text), do: c(text, IO.ANSI.cyan())
  def green(text), do: c(text, IO.ANSI.green())
  def yellow(text), do: c(text, IO.ANSI.yellow())
  def red(text), do: c(text, IO.ANSI.red())
  def magenta(text), do: c(text, IO.ANSI.magenta())
  def blue(text), do: c(text, IO.ANSI.blue())
  def bright(text), do: c(text, IO.ANSI.bright())
  def faint(text), do: c(text, IO.ANSI.faint())

  def risk(:high), do: red("high")
  def risk("high"), do: red("high")
  def risk(:medium), do: yellow("medium")
  def risk("medium"), do: yellow("medium")
  def risk(:low), do: green("low")
  def risk("low"), do: green("low")
  def risk(other), do: to_string(other)

  def effect("pure"), do: green("pure")
  def effect(:pure), do: green("pure")
  def effect("unknown"), do: yellow("unknown")
  def effect(:unknown), do: yellow("unknown")
  def effect("io"), do: cyan("io")
  def effect(:io), do: cyan("io")
  def effect("read"), do: blue("read")
  def effect(:read), do: blue("read")
  def effect("write"), do: magenta("write")
  def effect(:write), do: magenta("write")
  def effect("exception"), do: red("exception")
  def effect(:exception), do: red("exception")
  def effect("send"), do: magenta("send")
  def effect(:send), do: magenta("send")
  def effect(other), do: to_string(other)

  def effects_join(effects, separator \\ ", ") do
    Enum.map_join(effects, separator, &effect/1)
  end

  def humanize(value) do
    value
    |> to_string()
    |> String.replace("_", " ")
  end

  def humanized_join(values, separator \\ ", ") do
    Enum.map_join(values, separator, &humanize/1)
  end

  # ── Rendering ──

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
    output = %Reach.CLI.JSONEnvelope{
      command: tool,
      tool: tool,
      data: jsonify(data)
    }

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

  # ── JSON encoding ──

  def jsonify(%Reach.IR.Node{} = node) do
    %{type: Atom.to_string(node.type), id: node.id}
    |> maybe_add(:name, node.meta[:name])
    |> maybe_add(:module, node.meta[:module])
    |> maybe_add(:function, node.meta[:function])
    |> maybe_add(:location, raw_location(node))
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

  # ── Formatting ──

  def location(node) do
    case node.source_span do
      %{file: f, start_line: l} ->
        loc(f, l)

      _ ->
        "unknown"
    end
  end

  def raw_location(node) do
    case node.source_span do
      %{file: f, start_line: l} -> "#{f}:#{l}"
      _ -> "unknown"
    end
  end

  def loc(file, line) when is_binary(file) do
    faint(path(file) <> ":" <> to_string(line))
  end

  def loc(raw, _), do: faint(to_string(raw))

  def location_text("unknown"), do: "unknown"

  def location_text(location) when is_binary(location) do
    case Regex.run(~r/^(.*):(\d+)$/, location) do
      [_match, file, line] -> loc(file, line)
      _ -> faint(location)
    end
  end

  def path(file) when is_binary(file) do
    expanded = Path.expand(file)

    case Project.display_root() do
      nil -> file
      root -> relative_to_root(expanded, root)
    end
  end

  def path(other), do: to_string(other)

  defp relative_to_root(path, root) do
    relative = Path.relative_to(path, root)

    if String.starts_with?(relative, ".."), do: path, else: relative
  end

  def func_id_to_string(func_id), do: IRHelpers.func_id_to_string(func_id)

  def header(title) do
    width = max(String.length(title) + 4, 40)
    line = cyan(String.duplicate("─", width))
    "\n#{line}\n  #{bright(title)}\n#{line}"
  end

  def section(title) do
    "\n#{cyan(title)}\n#{cyan(String.duplicate("─", String.length(title)))}"
  end

  def tree_line(item, last?) do
    prefix = if last?, do: "└── ", else: "├── "
    "#{faint(prefix)}#{item}"
  end

  def indent(text, n \\ 2) do
    pad = String.duplicate(" ", n)
    String.split(text, "\n") |> Enum.map_join("\n", &(pad <> &1))
  end

  def tag(:warning), do: yellow("⚠")
  def tag(:error), do: red("✗")
  def tag(:ok), do: green("✓")
  def tag(:info), do: cyan("ℹ")

  def warning(text), do: yellow(text) <> " " <> tag(:warning)
  def omitted(text), do: faint("… " <> text)
  def empty(text \\ "none"), do: faint("(#{text})")
  def count(n), do: bright(to_string(n))
  def summary(text), do: faint(text)

  def threshold_color(value, warn, crit) do
    cond do
      value >= crit -> red(to_string(value))
      value >= warn -> yellow(to_string(value))
      true -> to_string(value)
    end
  end

  def call_name(node), do: IRHelpers.call_name(node)

  defp maybe_add(map, _key, nil), do: map
  defp maybe_add(map, key, val), do: Map.put(map, key, jsonify(val))
end
