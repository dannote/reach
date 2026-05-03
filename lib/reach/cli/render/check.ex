defmodule Reach.CLI.Render.Check do
  @moduledoc false

  alias Reach.CLI.Format

  @text_limit 30

  def render_no_default do
    IO.puts("No default Reach checks configured.")
    IO.puts("Use --arch, --changed, --dead-code, --smells, or --candidates.")
  end

  def render_result(result, "json", _text_fun) do
    ensure_json_encoder!()
    IO.puts(Jason.encode!(json_envelope(result), pretty: true))
  end

  def render_result(result, _format, text_fun), do: text_fun.(result)

  def render_candidates_text(%{candidates: []}) do
    IO.puts(Format.header("Refactoring Candidates"))
    IO.puts("  " <> Format.empty("no refactoring candidates"))
  end

  def render_candidates_text(%{candidates: candidates, note: note}) do
    IO.puts(Format.header("Refactoring Candidates (#{length(candidates)})"))
    IO.puts(Format.faint(note))
    IO.puts("")

    Enum.each(candidates, fn candidate ->
      IO.puts(
        "  #{Format.bright(candidate.id)} #{Format.yellow(Format.humanize(candidate.kind))}: #{candidate.target}"
      )

      IO.puts(
        "    benefit=#{candidate.benefit} risk=#{Format.risk(candidate.risk)} confidence=#{Format.risk(candidate[:confidence] || :unknown)}"
      )

      if candidate[:file] do
        IO.puts("    #{Format.loc(candidate.file, candidate.line)}")
      end

      IO.puts("    evidence=#{Format.humanized_join(candidate.evidence)}")

      render_representative_calls(candidate)

      IO.puts("    suggestion=#{candidate.suggestion}")
      IO.puts("")
    end)
  end

  def render_arch_text(%{violations: []}) do
    IO.puts(Format.header("Architecture Policy"))
    IO.puts("  #{Format.green("OK")}")
  end

  def render_arch_text(%{violations: violations}) do
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

  def render_changed_text(result) do
    IO.puts(Format.header("Changed Code"))
    IO.puts("  base=#{result.base} risk=#{risk_label(result.risk)}")

    if result.risk_reasons != [] do
      IO.puts("  reasons=#{Enum.join(result.risk_reasons, ", ")}")
    end

    []
    |> add_omitted(
      render_limited_section("Changed files", result.changed_files, &IO.puts("  #{&1}"))
    )
    |> add_omitted(
      render_limited_section("Changed functions", result.changed_functions, fn function ->
        IO.puts(
          "  #{Format.bright(function.id)} #{Format.loc(function.file, function.line)} risk=#{risk_label(function.risk)} callers=#{function.direct_caller_count}/#{function.transitive_caller_count} branches=#{function.branch_count} effects=#{Format.effects_join(function.effects)}"
        )
      end)
    )
    |> add_omitted(
      render_limited_section("Public API touched", result.public_api_changes, fn function ->
        IO.puts("  #{Format.bright(function.id)} #{Format.loc(function.file, function.line)}")
      end)
    )
    |> add_omitted(
      render_limited_section(
        "Suggested tests",
        result.suggested_tests,
        &IO.puts("  mix test #{&1}")
      )
    )
    |> render_omitted_summary()
  end

  defp render_representative_calls(%{representative_calls: calls}) when calls != [] do
    IO.puts("    representative calls:")

    Enum.each(calls, fn call ->
      IO.puts("      #{Format.loc(call.file, call.line)} #{call.caller_module} -> #{call.call}")
    end)
  end

  defp render_representative_calls(_candidate), do: :ok

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
