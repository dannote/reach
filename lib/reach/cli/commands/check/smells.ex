defmodule Reach.CLI.Commands.Check.Smells do
  @moduledoc false

  alias Reach.Check.Smells, as: SmellsCheck
  alias Reach.CLI.Format
  alias Reach.CLI.Project
  alias Reach.Smell.Finding

  @evidence_display_limit 4

  def run(opts, positional, command \\ "reach.check") do
    format = opts[:format] || "text"
    path = opts[:path] || List.first(positional)

    project_opts = [quiet: opts[:format] == "json"]
    project_opts = if path, do: Keyword.put(project_opts, :paths, [path]), else: project_opts
    project = Project.load(project_opts)

    findings = SmellsCheck.run(project)
    render(findings, format, command)
  end

  defp render(findings, "json", command) do
    Format.render(%{findings: Enum.map(findings, &Finding.to_map/1)}, command,
      format: "json",
      pretty: true
    )
  end

  defp render(findings, "oneline", _command) do
    Enum.each(findings, fn f ->
      IO.puts("#{f.location}: #{Format.yellow(to_string(f.kind))}: #{f.message}")
    end)
  end

  defp render(findings, _format, _command) do
    IO.puts(Format.header("Cross-Function Smell Detection"))

    if findings == [] do
      IO.puts("  " <> Format.empty("no issues"))
      IO.puts("")
    else
      grouped = Enum.group_by(findings, & &1.kind)

      render_group(Map.get(grouped, :redundant_traversal, []), "Redundant traversals")
      render_group(Map.get(grouped, :suboptimal, []), "Suboptimal patterns")
      render_group(Map.get(grouped, :redundant_computation, []), "Redundant computations")
      render_group(Map.get(grouped, :eager_pattern, []), "Eager where lazy suffices")
      render_group(Map.get(grouped, :string_building, []), "String building (use iolists)")
      render_group(Map.get(grouped, :dual_key_access, []), "Loose map contracts")
      render_group(Map.get(grouped, :fixed_shape_map, []), "Repeated map shapes")

      IO.puts("#{length(findings)} finding(s)\n")
    end
  end

  defp render_group([], _title), do: nil

  defp render_group(findings, title) do
    IO.puts(Format.section(title))
    Enum.each(findings, &render_finding/1)
  end

  defp render_finding(%Finding{kind: :fixed_shape_map} = finding) do
    IO.puts("  #{finding.location}")

    summary =
      [
        Format.yellow("#{finding.occurrences}x"),
        Format.bright(Enum.join(finding.keys, ", ")),
        Format.faint("consider a struct or explicit contract")
      ]
      |> Enum.join("  ")

    IO.puts("    #{summary}")
    render_evidence(finding.evidence, finding.location)
  end

  defp render_finding(finding) do
    IO.puts("  #{finding.location}")
    IO.puts("    #{Format.yellow(finding.message)}")
  end

  defp render_evidence(evidence, primary_location) when is_list(evidence) do
    evidence
    |> Enum.reject(&(&1 == primary_location))
    |> Enum.take(@evidence_display_limit)
    |> case do
      [] ->
        :ok

      locations ->
        IO.puts("    #{Format.faint("also:")}")
        Enum.each(locations, &IO.puts("      #{&1}"))
    end
  end

  defp render_evidence(_evidence, _primary_location), do: :ok
end
