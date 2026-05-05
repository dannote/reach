defmodule Reach.CLI.Render.Trace.Flow do
  @moduledoc false

  alias Reach.CLI.Format

  def render(result, format, limit, command) do
    case format do
      "json" -> Format.render(result, command, format: "json", pretty: true)
      "oneline" -> render_oneline(result)
      _ -> render_text(result, limit)
    end
  end

  defp render_text(result, limit) do
    case result.type do
      :taint -> render_taint_text(result, limit)
      :variable -> render_variable_text(result, limit)
    end
  end

  defp render_taint_text(result, limit) do
    IO.puts(Format.header("Taint: #{result.from} → #{result.to}"))

    if result.paths == [] do
      IO.puts("\n  " <> Format.empty("no data flow paths") <> "\n")
    else
      shown = take_limited(result.paths, limit)
      IO.puts("#{length(result.paths)} path(s) found. Showing #{length(shown)}.\n")
      shown |> Enum.with_index() |> Enum.each(&print_path/1)
      render_omitted_hint(length(result.paths) - length(shown), "path(s)")
    end
  end

  defp print_path({path, index}) do
    IO.puts("Path #{index + 1}:")
    IO.puts("  #{fmt_node(path.source)}")
    Enum.each(path.intermediate, fn node -> IO.puts("  #{fmt_node(node)}") end)
    IO.puts("  #{fmt_node(path.sink)}")
    IO.puts("")
  end

  defp render_variable_text(result, limit) do
    IO.puts(Format.header("Variable: #{result.variable}"))
    IO.puts("  definitions=#{length(result.definitions)} uses=#{length(result.uses)}")

    IO.puts(Format.section("Definitions"))
    render_limited_nodes(result.definitions, limit)

    IO.puts(Format.section("Uses"))
    render_limited_nodes(result.uses, limit)
  end

  defp render_limited_nodes([], _limit), do: IO.puts("  " <> Format.empty())

  defp render_limited_nodes(nodes, limit) do
    shown = take_limited(nodes, limit)
    Enum.each(shown, fn node -> IO.puts("  #{fmt_node(node)}") end)

    render_omitted_hint(length(nodes) - length(shown), "more")
  end

  defp take_limited(items, :all), do: items
  defp take_limited(items, limit), do: Enum.take(items, limit)

  defp render_omitted_hint(remaining, _label) when remaining <= 0, do: :ok

  defp render_omitted_hint(remaining, label) do
    IO.puts(
      "  " <>
        Format.omitted("#{remaining} #{label} omitted. Use --limit N, --all, or --format json.")
    )
  end

  defp fmt_node(node) do
    loc = Format.location(node)

    desc =
      case node.type do
        :var -> "var #{node.meta[:name]}"
        :call -> Format.call_name(node)
        other -> to_string(other)
      end

    "#{loc}  #{desc}"
  end

  defp render_oneline(result) do
    case result.type do
      :taint ->
        Enum.each(result.paths, fn path ->
          src = Format.location(path.source)
          sink = Format.location(path.sink)
          IO.puts("#{src} → #{sink}")
        end)

      :variable ->
        Enum.each(result.definitions, fn node ->
          IO.puts("def:#{Format.location(node)}:#{result.variable}")
        end)

        Enum.each(result.uses, fn node ->
          IO.puts("use:#{Format.location(node)}:#{result.variable}")
        end)
    end
  end
end
