defmodule Reach.CLI.Render.Trace.Slice do
  @moduledoc false

  alias Reach.CLI.Format
  alias Reach.Trace.Slice

  def render(result, target, format, command) do
    case format do
      "json" -> render_json(result, target, command)
      "oneline" -> render_oneline(result)
      _ -> render_text(result)
    end
  end

  defp render_json(result, target, command) do
    Format.render(
      %{
        target: %{file: target.file, line: target.line, node_id: result.node.id},
        direction: to_string(result.direction),
        statements: result.statements
      },
      command,
      format: "json",
      pretty: true
    )
  end

  defp render_oneline(result) do
    Enum.each(result.statements, fn statement ->
      IO.puts("#{statement.file}:#{statement.line}: #{statement.description}")
    end)
  end

  defp render_text(result) do
    forward? = result.direction == :forward
    direction = if forward?, do: "Forward", else: "Backward"
    target_desc = Slice.describe_node(result.node)
    loc = Format.location(result.node)

    IO.puts(Format.header("#{direction} slice of #{target_desc} (#{loc})"))

    if result.statements == [] do
      hint = if forward?, do: "", else: " Try --forward to see where this value flows."
      IO.puts("No dependencies found.#{hint}")
    else
      Enum.each(result.statements, fn statement ->
        IO.puts(
          "  #{Format.faint(Path.basename(statement.file) <> ":" <> to_string(statement.line))}  #{statement.description}"
        )
      end)

      files = result.statements |> Enum.map(& &1.file) |> Enum.uniq() |> length()
      IO.puts("\n#{Format.count(length(result.statements))} statements, #{files} file(s)")
    end
  end
end
