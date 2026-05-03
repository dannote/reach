defmodule Reach.CLI.Commands.Inspect.Impact do
  @moduledoc false

  alias Reach.CLI.BoxartGraph
  alias Reach.CLI.Format
  alias Reach.CLI.Project
  alias Reach.Inspect.Impact, as: ImpactAnalysis

  def run_target(raw_target, opts, command \\ "reach.inspect") do
    project = Project.load(quiet: opts[:format] == "json")
    target = Project.resolve_target(project, raw_target)

    unless target do
      Mix.raise("Function not found: #{raw_target}")
    end

    depth = opts[:depth] || 4
    result = ImpactAnalysis.analyze(project, target, depth)
    render(project, target, depth, result, opts, command)
  end

  defp render(project, target, depth, _result, %{graph: true}, _command) do
    BoxartGraph.require!()
    BoxartGraph.render_caller_graph(project, target, depth)
  end

  defp render(project, _target, _depth, result, opts, command) do
    case opts[:format] || "text" do
      "json" -> Format.render(result, command, format: "json", pretty: true)
      "oneline" -> render_oneline(result)
      _ -> render_text(project, result)
    end
  end

  defp render_text(project, result) do
    target_str = Format.func_id_to_string(result.target)
    IO.puts("If you change #{target_str}:")

    render_caller_section(
      project,
      result.direct_callers,
      "Direct callers (break on signature change)"
    )

    render_caller_section(
      project,
      result.transitive_callers,
      "Transitive callers (break on behavior change)"
    )

    render_return_deps_section(result.return_dependents)
    render_risk_summary(result)
  end

  defp render_caller_section(project, callers, title) do
    IO.puts(Format.section(title))

    case callers do
      [] -> IO.puts("  " <> Format.empty())
      list -> Enum.each(list, &print_func_with_location(project, &1.id))
    end
  end

  defp render_return_deps_section(return_dependents) do
    IO.puts(Format.section("Return value dependents (break on output shape change)"))

    case return_dependents do
      [] ->
        IO.puts("  " <> Format.empty())

      deps ->
        Enum.each(deps, fn dep ->
          IO.puts(
            "  #{Format.func_id_to_string(dep.in_function)} → #{Format.location_text(dep.location)}"
          )
        end)
    end
  end

  defp render_risk_summary(result) do
    total = length(result.direct_callers) + length(result.transitive_callers)

    risk =
      cond do
        total > 8 -> "HIGH"
        total > 3 -> "MEDIUM"
        true -> "LOW"
      end

    IO.puts("\n#{total} affected function(s), risk: #{risk}\n")
  end

  defp print_func_with_location(project, func_id) do
    location = Project.func_location(project, func_id)
    IO.puts("  #{Format.func_id_to_string(func_id)}  #{location}")
  end

  defp render_oneline(result) do
    target_str = Format.func_id_to_string(result.target)

    Enum.each(result.direct_callers, fn %{id: id} ->
      IO.puts("#{target_str}:direct_caller:#{Format.func_id_to_string(id)}")
    end)

    Enum.each(result.transitive_callers, fn %{id: id} ->
      IO.puts("#{target_str}:transitive_caller:#{Format.func_id_to_string(id)}")
    end)
  end
end
