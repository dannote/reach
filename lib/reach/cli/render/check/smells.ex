defmodule Reach.CLI.Render.Check.Smells do
  @moduledoc false

  alias Reach.CLI.Format
  alias Reach.Smell.Finding

  @evidence_display_limit 4

  def render(findings, "json", command) do
    Format.render(%{findings: Enum.map(findings, &Finding.to_map/1)}, command,
      format: "json",
      pretty: true
    )
  end

  def render(findings, "oneline", _command) do
    Enum.each(findings, fn finding ->
      IO.puts(
        "#{Format.location_text(finding.location)}: #{Format.yellow(to_string(finding.kind))}: #{finding.message}"
      )
    end)
  end

  def render(findings, _format, _command) do
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
    IO.puts("  #{Format.location_text(finding.location)}")

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
    IO.puts("  #{Format.location_text(finding.location)}")
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
        Enum.each(locations, &IO.puts("      #{Format.location_text(&1)}"))
    end
  end

  defp render_evidence(_evidence, _primary_location), do: :ok
end
