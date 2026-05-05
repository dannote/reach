defmodule Reach.CLI.Render.Check.DeadCode do
  @moduledoc false

  alias Reach.CLI.Format

  def render(findings, "json", command) do
    Format.render(%{findings: findings}, command, format: "json", pretty: true)
  end

  def render(findings, "oneline", _command) do
    Enum.each(findings, fn finding ->
      IO.puts(
        "#{Format.faint("#{finding.file}:#{finding.line}")}: #{Format.yellow(to_string(finding.kind))}: #{finding.description}"
      )
    end)
  end

  def render([], _format, _command) do
    IO.puts(Format.header("Dead Code"))
    IO.puts("  " <> Format.empty())
  end

  def render(findings, _format, _command) do
    IO.puts(Format.header("Dead Code"))

    findings
    |> Enum.group_by(& &1.file)
    |> Enum.sort_by(fn {file, _} -> file end)
    |> Enum.each(fn {file, file_findings} ->
      IO.puts(Format.section(Format.faint(file)))

      Enum.each(file_findings, fn finding ->
        IO.puts("  line #{Format.yellow(to_string(finding.line))}: #{finding.description}")
      end)
    end)

    IO.puts("\n#{Format.count(length(findings))} finding(s)\n")
  end
end
