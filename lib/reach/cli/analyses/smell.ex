defmodule Reach.CLI.Analyses.Smell do
  @moduledoc """
  Finds local structural and performance smells.

  Detects redundant traversals, duplicate computations, eager Enum/List
  patterns, string-building patterns, and loose map contracts such as mixed
  atom/string key access.

      mix reach.check --smells
      mix reach.check --smells --format json
      mix reach.check --smells lib/my_app/

  ## Options

    * `--format` — output format: `text` (default), `json`, `oneline`

  """

  @switches [format: :string, path: :string]
  @aliases [f: :format]

  alias Reach.CLI.Analyses.Smell.Finding
  alias Reach.CLI.Format
  alias Reach.CLI.Options
  alias Reach.CLI.Project

  def run(args, cli_opts \\ []) do
    {opts, positional} = Options.parse(args, @switches, @aliases)
    run_opts(opts, positional, cli_opts)
  end

  def run_opts(opts, positional \\ [], cli_opts \\ []) do
    format = opts[:format] || "text"
    path = opts[:path] || List.first(positional)

    project_opts = [quiet: opts[:format] == "json"]
    project_opts = if path, do: Keyword.put(project_opts, :paths, [path]), else: project_opts
    project = Project.load(project_opts)

    findings = analyze(project)

    case format do
      "json" ->
        Format.render(%{findings: Enum.map(findings, &Finding.to_map/1)}, command(cli_opts),
          format: "json",
          pretty: true
        )

      "oneline" ->
        Enum.each(findings, fn f ->
          IO.puts("#{f.location}: #{Format.yellow(to_string(f.kind))}: #{f.message}")
        end)

      _ ->
        render_text(findings)
    end
  end

  defp command(cli_opts), do: Keyword.get(cli_opts, :command, "reach.check")

  @doc false
  def analyze(project), do: run_checks(project)

  defp run_checks(project),
    do: Enum.flat_map(Reach.CLI.Analyses.Smell.Registry.checks(), & &1.run(project))

  # --- Rendering ---

  defp render_text(findings) do
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
    |> Enum.take(4)
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
