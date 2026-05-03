defmodule Reach.CLI.Commands.Check.DeadCode do
  @moduledoc false

  alias Reach.Check.DeadCode, as: DeadCodeCheck
  alias Reach.CLI.Format
  alias Reach.CLI.Project

  def run(opts, positional, command \\ "reach.check") do
    format = opts[:format] || "text"

    Project.compile(opts[:format] == "json")

    files = DeadCodeCheck.collect_files(opts[:path] || List.first(positional))
    unless format == "json", do: Mix.shell().info("Analyzing #{length(files)} file(s)...")

    findings = DeadCodeCheck.run(files)
    render(findings, format, command)
  end

  defp render(findings, "json", command) do
    Format.render(%{findings: findings}, command, format: "json", pretty: true)
  end

  defp render(findings, "oneline", _command) do
    Enum.each(findings, fn f ->
      IO.puts(
        "#{Format.faint("#{f.file}:#{f.line}")}: #{Format.yellow(to_string(f.kind))}: #{f.description}"
      )
    end)
  end

  defp render([], _format, _command) do
    IO.puts(Format.header("Dead Code"))
    IO.puts("  " <> Format.empty())
  end

  defp render(findings, _format, _command) do
    IO.puts(Format.header("Dead Code"))

    findings
    |> Enum.group_by(& &1.file)
    |> Enum.sort_by(fn {file, _} -> file end)
    |> Enum.each(fn {file, file_findings} ->
      IO.puts(Format.section(Format.faint(file)))

      Enum.each(file_findings, fn f ->
        IO.puts("  line #{Format.yellow(to_string(f.line))}: #{f.description}")
      end)
    end)

    IO.puts("\n#{Format.count(length(findings))} finding(s)\n")
  end
end
