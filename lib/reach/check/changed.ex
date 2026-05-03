defmodule Reach.Check.Changed do
  @moduledoc false

  alias Reach.Check.Architecture
  alias Reach.Config
  alias Reach.IR
  alias Reach.IR.Helpers, as: IRHelpers
  alias Reach.Project.Query

  def run(project, config, opts \\ []) do
    base = Keyword.get(opts, :base) || default_base_ref()
    files = changed_files(base)
    changed_ranges = changed_ranges(base)
    functions = changed_functions(project, changed_ranges, config)
    normalized_config = Config.normalize(config)
    tests = suggested_tests(files, functions, normalized_config.tests.hints)
    {risk, risk_reasons} = aggregate_change_risk(functions)

    %{
      base: base,
      risk: risk,
      risk_reasons: risk_reasons,
      changed_files: files,
      changed_functions: functions,
      public_api_changes: Enum.filter(functions, & &1.public_api),
      suggested_tests: tests
    }
  end

  def default_base_ref do
    cond do
      git_ref?("main") -> "main"
      git_ref?("master") -> "master"
      upstream = git_upstream() -> upstream
      true -> "HEAD"
    end
  end

  def changed_files(base) do
    case System.cmd("git", ["diff", "--name-only", base <> "...HEAD"], stderr_to_stdout: true) do
      {output, 0} -> output |> String.split("\n", trim: true) |> Enum.reject(&(&1 == ""))
      {output, _status} -> Mix.raise("Could not read changed files against #{base}: #{output}")
    end
  end

  def changed_ranges(base) do
    case System.cmd("git", ["diff", "--unified=0", base <> "...HEAD"], stderr_to_stdout: true) do
      {output, 0} -> parse_diff_ranges(output)
      {output, _status} -> Mix.raise("Could not read changed ranges against #{base}: #{output}")
    end
  end

  def changed_functions(project, changed_ranges, config) do
    changed_ranges
    |> Enum.flat_map(fn {file, ranges} ->
      ranges
      |> Enum.flat_map(fn {first, last} -> first..last end)
      |> Enum.map(&Query.find_function_at_location(project, file, &1))
      |> Enum.reject(&is_nil/1)
    end)
    |> Enum.uniq_by(&{&1.meta[:module], &1.meta[:name], &1.meta[:arity]})
    |> Enum.map(&function_summary(project, &1, Config.normalize(config)))
    |> Enum.sort_by(&{&1.file || "", &1.line || 0, &1.id})
  end

  def aggregate_change_risk([]), do: {:low, []}

  def aggregate_change_risk(functions) do
    reasons =
      functions
      |> Enum.flat_map(& &1.risk_reasons)
      |> Enum.frequencies()
      |> Enum.sort_by(fn {reason, count} -> {-count, reason} end)
      |> Enum.map(fn {reason, count} -> "#{reason} (#{count})" end)

    risk =
      cond do
        Enum.any?(functions, &(&1.risk == :high)) -> :high
        Enum.any?(functions, &(&1.risk == :medium)) -> :medium
        true -> :low
      end

    {risk, reasons}
  end

  def branch_count(func) do
    func
    |> IR.all_nodes()
    |> Enum.count(
      &(&1.type in [:case, :receive, :try] or
          (&1.type == :binary_op and &1.meta[:operator] in [:and, :or, :&&, :||]))
    )
  end

  def suggested_tests(files, functions, hints) do
    hint_tests =
      hints
      |> Enum.flat_map(fn {pattern, tests} ->
        if Enum.any?(files, &Architecture.glob_match?(&1, to_string(pattern))),
          do: tests,
          else: []
      end)

    proximity_tests =
      files
      |> Enum.flat_map(&test_paths_for_source/1)
      |> Enum.filter(&File.exists?/1)

    impact_tests =
      functions
      |> Enum.flat_map(&test_paths_for_source(&1.file))
      |> Enum.filter(&File.exists?/1)

    (hint_tests ++ proximity_tests ++ impact_tests)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp git_ref?(ref) do
    case System.cmd("git", ["rev-parse", "--verify", "--quiet", ref], stderr_to_stdout: true) do
      {_output, 0} -> true
      {_output, _status} -> false
    end
  end

  defp git_upstream do
    case System.cmd("git", ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"],
           stderr_to_stdout: true
         ) do
      {output, 0} -> String.trim(output)
      {_output, _status} -> nil
    end
  end

  defp parse_diff_ranges(output) do
    output
    |> String.split("\n")
    |> Enum.reduce({nil, %{}}, fn line, {file, acc} ->
      cond do
        String.starts_with?(line, "+++ b/") ->
          {String.replace_prefix(line, "+++ b/", ""), acc}

        String.starts_with?(line, "@@") and file not in [nil, "/dev/null"] ->
          {file, add_hunk_range(acc, file, parse_hunk_range(line))}

        true ->
          {file, acc}
      end
    end)
    |> elem(1)
    |> Map.new(fn {file, ranges} -> {file, Enum.reverse(ranges)} end)
  end

  defp add_hunk_range(acc, _file, nil), do: acc
  defp add_hunk_range(acc, file, range), do: Map.update(acc, file, [range], &[range | &1])

  defp parse_hunk_range(line) do
    case Regex.run(~r/\+(\d+)(?:,(\d+))?/, line) do
      [_, start] -> {String.to_integer(start), String.to_integer(start)}
      [_, _start, "0"] -> nil
      [_, start, count] -> range_from_count(String.to_integer(start), String.to_integer(count))
    end
  end

  defp range_from_count(start, count), do: {start, start + count - 1}

  defp function_summary(project, func, config) do
    id = {func.meta[:module], func.meta[:name], func.meta[:arity]}
    direct_callers = Query.callers(project, id, 1)
    transitive_callers = Query.callers(project, id, 4)
    effects = Architecture.function_effects(func)
    branches = branch_count(func)
    thresholds = config.risk.changed

    {risk, reasons} =
      change_risk(func, direct_callers, transitive_callers, effects, branches, thresholds)

    %{
      id: IRHelpers.func_id_to_string(id),
      file: func.source_span && func.source_span.file,
      line: func.source_span && func.source_span.start_line,
      risk: risk,
      risk_reasons: reasons,
      public_api: public_api_function?(func, config),
      effects: Enum.map(effects, &to_string/1),
      branch_count: branches,
      direct_callers: Enum.map(direct_callers, &IRHelpers.func_id_to_string(&1.id)),
      direct_caller_count: length(direct_callers),
      transitive_caller_count: length(transitive_callers)
    }
  end

  defp public_api_function?(func, config) do
    func.meta[:kind] in [:def, :defmacro] and
      Architecture.module_matches_any?(
        func.meta[:module],
        List.wrap(Config.normalize(config).boundaries.public)
      )
  end

  defp change_risk(func, direct_callers, transitive_callers, effects, branches, thresholds) do
    reasons =
      []
      |> maybe_reason(
        length(direct_callers) >= thresholds.many_direct_callers,
        "many direct callers"
      )
      |> maybe_reason(
        length(transitive_callers) >= thresholds.wide_transitive_callers,
        "wide transitive impact"
      )
      |> maybe_reason(branches >= thresholds.branch_heavy, "branch-heavy function")
      |> maybe_reason(multiple?(effects -- [:pure]), "mixed side effects")
      |> maybe_reason(core_module?(func.meta[:module]), "core Reach module")

    risk =
      cond do
        length(reasons) >= thresholds.high_risk_reason_count -> :high
        reasons != [] -> :medium
        true -> :low
      end

    {risk, reasons}
  end

  defp multiple?([]), do: false
  defp multiple?([_one]), do: false
  defp multiple?([_one, _two | _rest]), do: true

  defp maybe_reason(reasons, true, reason), do: reasons ++ [reason]
  defp maybe_reason(reasons, false, _reason), do: reasons

  defp core_module?(module) do
    module in [
      Reach,
      Reach.Project,
      Reach.SystemDependence,
      Reach.ControlFlow,
      Reach.DataDependence
    ]
  end

  defp test_paths_for_source(nil), do: []

  defp test_paths_for_source(file) do
    cond do
      String.starts_with?(file, "lib/mix/tasks/") ->
        task = file |> Path.basename(".ex") |> String.replace(".", "_")

        [
          "test/reach/cli/legacy/#{task}_test.exs",
          "test/reach/cli/legacy/mix_task_#{String.replace(task, "reach_", "")}_test.exs",
          "test/reach/cli/canonical_tasks_test.exs"
        ]

      String.starts_with?(file, "lib/") ->
        base = file |> String.replace_prefix("lib/", "") |> Path.rootname()
        ["test/#{base}_test.exs", "test/reach/#{base}_test.exs"]

      true ->
        []
    end
  end
end
