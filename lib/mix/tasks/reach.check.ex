defmodule Mix.Tasks.Reach.Check do
  @moduledoc """
  Runs structural validation and change-safety checks.

      mix reach.check
      mix reach.check --arch
      mix reach.check --changed --base main
      mix reach.check --dead-code
      mix reach.check --smells
      mix reach.check --candidates

  ## Options

    * `--format` — output format: `text` or `json`
    * `--arch` — check `.reach.exs` architecture policy
    * `--changed` — report changed functions and configured test hints
    * `--base` — git base ref for `--changed` (default: auto-detect `main`, `master`, or upstream)
    * `--dead-code` — find unused pure expressions
    * `--smells` — find graph/effect/data-flow performance smells
    * `--candidates` — emit advisory refactoring candidates
    * `--top` — limit candidate output for `--candidates`

  """

  use Mix.Task

  alias Reach.Check.Architecture
  alias Reach.Check.Candidates
  alias Reach.Check.Changed
  alias Reach.CLI.Format
  alias Reach.CLI.Project
  alias Reach.CLI.TaskRunner

  @shortdoc "Structural validation and change-safety checks"
  @text_limit 30

  @switches [
    format: :string,
    arch: :boolean,
    changed: :boolean,
    base: :string,
    dead_code: :boolean,
    smells: :boolean,
    candidates: :boolean,
    path: :string,
    top: :integer
  ]

  @aliases [f: :format]

  @impl Mix.Task
  def run(args) do
    {opts, positional, _} = OptionParser.parse(args, switches: @switches, aliases: @aliases)

    cond do
      opts[:arch] ->
        run_arch(opts)

      opts[:changed] ->
        run_changed(opts)

      opts[:dead_code] ->
        TaskRunner.run("reach.dead_code", delegated_args(opts, positional),
          command: "reach.check"
        )

      opts[:smells] ->
        TaskRunner.run("reach.smell", delegated_args(opts, positional), command: "reach.check")

      opts[:candidates] ->
        render_candidates_placeholder(opts, positional)

      true ->
        run_default(opts)
    end
  end

  defp run_default(opts) do
    if File.exists?(".reach.exs") do
      run_arch(opts)
    else
      IO.puts("No default Reach checks configured.")
      IO.puts("Use --arch, --changed, --dead-code, --smells, or --candidates.")
    end
  end

  defp run_arch(opts) do
    config = load_config()

    result =
      case Architecture.config_violations(config) do
        [] ->
          project = Project.load(quiet: opts[:format] == "json")
          Architecture.run(project, config)

        violations ->
          %{config: ".reach.exs", status: "failed", violations: violations}
      end

    render_result(result, opts[:format], &render_arch_text/1)

    if result.violations != [] do
      Mix.raise("Architecture policy failed")
    end
  end

  defp load_config do
    unless File.exists?(".reach.exs") do
      Mix.raise("No .reach.exs architecture policy found")
    end

    {config, _binding} = Code.eval_file(".reach.exs")

    unless is_list(config) do
      Mix.raise(".reach.exs must evaluate to a keyword list")
    end

    config
  end

  defp run_changed(opts) do
    config = if File.exists?(".reach.exs"), do: load_config(), else: []
    project = Project.load(quiet: opts[:format] == "json")
    result = Changed.run(project, config, base: opts[:base])

    render_result(result, opts[:format], &render_changed_text/1)
  end

  defp render_candidates_placeholder(opts, positional) do
    project = load_candidates_project(opts, positional)
    config = if File.exists?(".reach.exs"), do: load_config(), else: []
    result = Candidates.run(project, config, top: opts[:top] || 40)

    render_result(result, opts[:format], &render_candidates_text/1)
  end

  defp load_candidates_project(opts, positional) do
    path = opts[:path] || List.first(positional)

    if path do
      Project.load(paths: [path], quiet: opts[:format] == "json")
    else
      Project.load(quiet: opts[:format] == "json")
    end
  end

  defp delegated_args(opts, positional) do
    []
    |> maybe_put("--format", opts[:format])
    |> maybe_put("--path", opts[:path])
    |> Kernel.++(positional)
  end

  defp maybe_put(args, _flag, nil), do: args
  defp maybe_put(args, flag, value), do: args ++ [flag, to_string(value)]

  defp render_candidates_text(%{candidates: []}) do
    IO.puts(Format.header("Refactoring Candidates"))
    IO.puts("  " <> Format.empty("no refactoring candidates"))
  end

  defp render_candidates_text(%{candidates: candidates, note: note}) do
    IO.puts(Format.header("Refactoring Candidates (#{length(candidates)})"))
    IO.puts(Format.faint(note))
    IO.puts("")

    Enum.each(candidates, fn candidate ->
      IO.puts(
        "  #{Format.bright(candidate.id)} #{Format.yellow(humanize(candidate.kind))}: #{candidate.target}"
      )

      IO.puts(
        "    benefit=#{candidate.benefit} risk=#{Format.risk(candidate.risk)} confidence=#{Format.risk(candidate[:confidence] || :unknown)}"
      )

      if candidate[:file] do
        IO.puts("    #{Format.loc(candidate.file, candidate.line)}")
      end

      IO.puts("    evidence=#{humanized_list(candidate.evidence)}")

      render_representative_calls(candidate)

      IO.puts("    suggestion=#{candidate.suggestion}")
      IO.puts("")
    end)
  end

  defp humanized_list(values), do: Enum.map_join(values, ", ", &humanize/1)

  defp humanize(value) do
    value
    |> to_string()
    |> String.replace("_", " ")
  end

  defp render_representative_calls(%{representative_calls: calls}) when calls != [] do
    IO.puts("    representative calls:")

    Enum.each(calls, fn call ->
      IO.puts("      #{Format.loc(call.file, call.line)} #{call.caller_module} -> #{call.call}")
    end)
  end

  defp render_representative_calls(_candidate), do: :ok

  defp render_result(result, "json", _text_fun) do
    ensure_json_encoder!()
    IO.puts(Jason.encode!(json_envelope(result), pretty: true))
  end

  defp render_result(result, _format, text_fun), do: text_fun.(result)

  defp render_arch_text(%{violations: []}) do
    IO.puts(Format.header("Architecture Policy"))
    IO.puts("  #{Format.green("OK")}")
  end

  defp render_arch_text(%{violations: violations}) do
    IO.puts(Format.header("Architecture Policy"))
    IO.puts("  #{Format.red("#{length(violations)} violation(s)")}")

    Enum.each(violations, fn
      %{type: "config_error"} = violation ->
        IO.puts("  config #{violation.key}: #{violation.message}")

      %{type: "forbidden_dependency"} = violation ->
        IO.puts(
          "  #{Format.loc(violation.file, violation.line)} #{violation.caller_layer} -> #{violation.callee_layer} " <>
            "#{violation.call}"
        )

      %{type: "layer_cycle"} = violation ->
        IO.puts("  layer cycle: #{Enum.join(violation.layers, " -> ")}")

      %{type: "effect_policy"} = violation ->
        IO.puts([
          "  #{Format.loc(violation.file, violation.line)} #{violation.module}.#{violation.function} disallowed effects: ",
          Format.effects_join(violation.disallowed_effects)
        ])

      %{type: type} = violation when type in ["public_api_boundary", "internal_boundary"] ->
        IO.puts(
          "  #{Format.loc(violation.file, violation.line)} #{violation.caller_module} -> #{violation.callee_module} #{violation.call} (#{violation.rule})"
        )
    end)
  end

  defp render_changed_text(result) do
    IO.puts(Format.header("Changed Code"))
    IO.puts("  base=#{result.base} risk=#{risk_label(result.risk)}")

    if result.risk_reasons != [] do
      IO.puts("  reasons=#{Enum.join(result.risk_reasons, ", ")}")
    end

    omitted = []

    omitted =
      add_omitted(
        omitted,
        render_limited_section("Changed files", result.changed_files, &IO.puts("  #{&1}"))
      )

    omitted =
      add_omitted(
        omitted,
        render_limited_section("Changed functions", result.changed_functions, fn function ->
          IO.puts(
            "  #{Format.bright(function.id)} #{Format.loc(function.file, function.line)} risk=#{risk_label(function.risk)} callers=#{function.direct_caller_count}/#{function.transitive_caller_count} branches=#{function.branch_count} effects=#{Format.effects_join(function.effects)}"
          )
        end)
      )

    omitted =
      add_omitted(
        omitted,
        render_limited_section("Public API touched", result.public_api_changes, fn function ->
          IO.puts("  #{Format.bright(function.id)} #{Format.loc(function.file, function.line)}")
        end)
      )

    omitted =
      add_omitted(
        omitted,
        render_limited_section(
          "Suggested tests",
          result.suggested_tests,
          &IO.puts("  mix test #{&1}")
        )
      )

    render_omitted_summary(omitted)
  end

  defp render_limited_section(_title, [], _render_fun), do: nil

  defp render_limited_section(title, items, render_fun) do
    item_count = length(items)
    IO.puts("\n#{Format.section("#{title} (#{item_count})")}")

    items
    |> Enum.take(@text_limit)
    |> Enum.each(render_fun)

    omitted = item_count - @text_limit

    if omitted > 0, do: {title, omitted}
  end

  defp add_omitted(omitted, nil), do: omitted
  defp add_omitted(omitted, entry), do: [entry | omitted]

  defp render_omitted_summary([]), do: :ok

  defp render_omitted_summary(omitted) do
    summary =
      omitted
      |> Enum.reverse()
      |> Enum.map(fn {title, count} -> [title, ": ", to_string(count)] end)
      |> Enum.intersperse(", ")
      |> IO.iodata_to_binary()

    IO.puts(
      "\n" <>
        Format.omitted("Output truncated (#{summary}). Use --format json for complete output.")
    )
  end

  defp risk_label(risk), do: Format.risk(risk)

  defp json_envelope(result) do
    %Reach.CLI.JSONEnvelope{
      command: Map.get(result, :command, "reach.check"),
      data: Map.delete(result, :command)
    }
  end

  defp ensure_json_encoder! do
    unless Code.ensure_loaded?(Jason) do
      Mix.raise("Jason is required for JSON output. Add {:jason, \"~> 1.0\"} to your deps.")
    end
  end
end
