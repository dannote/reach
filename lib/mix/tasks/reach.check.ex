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
    * `--base` — git base ref for `--changed` (default: `main`)
    * `--dead-code` — find unused pure expressions
    * `--smells` — find graph/effect/data-flow performance smells
    * `--candidates` — emit advisory refactoring candidate placeholder

  """

  use Mix.Task

  alias Reach.CLI.Format
  alias Reach.CLI.Project
  alias Reach.CLI.TaskRunner
  alias Reach.Effects
  alias Reach.IR

  @shortdoc "Structural validation and change-safety checks"

  @switches [
    format: :string,
    arch: :boolean,
    changed: :boolean,
    base: :string,
    dead_code: :boolean,
    smells: :boolean,
    candidates: :boolean,
    path: :string
  ]

  @aliases [f: :format]

  @impl Mix.Task
  def run(args) do
    {opts, positional, _} = OptionParser.parse(args, switches: @switches, aliases: @aliases)

    cond do
      opts[:arch] -> run_arch(opts)
      opts[:changed] -> run_changed(opts)
      opts[:dead_code] -> TaskRunner.run("reach.dead_code", delegated_args(opts, positional))
      opts[:smells] -> TaskRunner.run("reach.smell", delegated_args(opts, positional))
      opts[:candidates] -> render_candidates_placeholder(opts)
      true -> run_default(opts)
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
    project = Project.load()
    layer_graph = layer_graph(project, config)

    violations =
      dependency_violations(project, config, layer_graph) ++
        layer_cycle_violations(layer_graph) ++
        effect_policy_violations(project, config)

    result = %{
      config: ".reach.exs",
      status: if(violations == [], do: "ok", else: "failed"),
      violations: violations
    }

    render_result(result, opts[:format], &render_arch_text/1)

    if violations != [] do
      System.halt(1)
    end
  end

  defp load_config do
    unless File.exists?(".reach.exs") do
      Mix.raise("No .reach.exs architecture policy found")
    end

    {config, _binding} = Code.eval_file(".reach.exs")
    config
  end

  defp layer_graph(project, config) do
    layers = Keyword.get(config, :layers, [])
    module_by_file = module_by_file(project)

    edges =
      project.nodes
      |> Map.values()
      |> Enum.filter(&remote_call?/1)
      |> Enum.flat_map(fn node ->
        caller_module = node.source_span && Map.get(module_by_file, node.source_span.file)
        callee_module = node.meta[:module]

        with caller when not is_nil(caller) <- caller_module,
             callee when not is_nil(callee) <- callee_module,
             caller_layer when not is_nil(caller_layer) <- module_layer(caller, layers),
             callee_layer when not is_nil(callee_layer) <- module_layer(callee, layers),
             true <- caller_layer != callee_layer do
          [%{from: caller_layer, to: callee_layer, node: node, caller: caller, callee: callee}]
        else
          _ -> []
        end
      end)

    %{edges: edges, adjacency: adjacency(edges)}
  end

  defp adjacency(edges) do
    Enum.reduce(edges, %{}, fn edge, acc ->
      Map.update(acc, edge.from, MapSet.new([edge.to]), &MapSet.put(&1, edge.to))
    end)
  end

  defp dependency_violations(_project, config, layer_graph) do
    forbidden = Keyword.get(config, :forbidden_deps, [])

    layer_graph.edges
    |> Enum.filter(&({&1.from, &1.to} in forbidden))
    |> Enum.map(fn edge ->
      %{
        type: "forbidden_dependency",
        caller_module: inspect(edge.caller),
        caller_layer: edge.from,
        callee_module: inspect(edge.callee),
        callee_layer: edge.to,
        file: edge.node.source_span.file,
        line: edge.node.source_span.start_line,
        call: "#{inspect(edge.callee)}.#{edge.node.meta[:function]}/#{edge.node.meta[:arity]}"
      }
    end)
  end

  defp layer_cycle_violations(%{adjacency: adjacency}) do
    adjacency
    |> Map.keys()
    |> Enum.flat_map(&walk_layer_cycle(adjacency, &1, &1, []))
    |> Enum.map(&canonical_cycle/1)
    |> Enum.uniq()
    |> Enum.map(fn cycle -> %{type: "layer_cycle", layers: cycle} end)
  end

  defp walk_layer_cycle(_adjacency, start, current, path) when length(path) > 8 do
    if current == start and path != [], do: [Enum.reverse(path)], else: []
  end

  defp walk_layer_cycle(adjacency, start, current, path) do
    adjacency
    |> Map.get(current, MapSet.new())
    |> Enum.flat_map(fn next ->
      cond do
        next == start and path != [] -> [Enum.reverse([current | path])]
        next in path -> []
        true -> walk_layer_cycle(adjacency, start, next, [current | path])
      end
    end)
  end

  defp canonical_cycle(cycle) do
    cycle
    |> Enum.map(&to_string/1)
    |> Enum.sort()
  end

  defp effect_policy_violations(project, config) do
    policies = Keyword.get(config, :allowed_effects, [])

    project.nodes
    |> Map.values()
    |> Enum.filter(&(&1.type == :function_def))
    |> Enum.flat_map(fn func ->
      module = func.meta[:module]
      allowed = allowed_effects_for(module, policies)

      if allowed do
        effects = function_effects(func)
        disallowed = effects -- allowed

        if disallowed == [] do
          []
        else
          [
            %{
              type: "effect_policy",
              module: inspect(module),
              function: "#{func.meta[:name]}/#{func.meta[:arity]}",
              allowed_effects: Enum.map(allowed, &to_string/1),
              actual_effects: Enum.map(effects, &to_string/1),
              disallowed_effects: Enum.map(disallowed, &to_string/1),
              file: func.source_span && func.source_span.file,
              line: func.source_span && func.source_span.start_line
            }
          ]
        end
      else
        []
      end
    end)
  end

  defp allowed_effects_for(module, policies) do
    Enum.find_value(policies, fn {pattern, effects} ->
      if module_matches_any?(module, [pattern]), do: effects
    end)
  end

  defp function_effects(func) do
    func
    |> IR.all_nodes()
    |> Enum.map(&Effects.classify/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp remote_call?(node) do
    node.type == :call and node.meta[:kind] == :remote and node.meta[:module] != nil
  end

  defp module_by_file(project) do
    project.nodes
    |> Map.values()
    |> Enum.filter(&(&1.type == :module_def and &1.source_span))
    |> Map.new(fn node -> {node.source_span.file, node.meta[:name]} end)
  end

  defp module_layer(module, layers) do
    Enum.find_value(layers, fn {layer, patterns} ->
      if module_matches_any?(module, List.wrap(patterns)), do: layer
    end)
  end

  defp module_matches_any?(module, patterns) do
    name = inspect(module)
    Enum.any?(patterns, &glob_match?(name, to_string(&1)))
  end

  defp glob_match?(value, pattern) do
    pattern_regex =
      pattern
      |> Regex.escape()
      |> String.replace("\\*\\*", ".*")
      |> String.replace("\\*", "[^/]*")

    Regex.match?(~r/^#{pattern_regex}$/, value)
  end

  defp run_changed(opts) do
    base = opts[:base] || "main"
    config = if File.exists?(".reach.exs"), do: load_config(), else: []
    project = Project.load()
    files = changed_files(base)
    changed_ranges = changed_ranges(base)
    functions = changed_functions(project, changed_ranges)
    tests = suggested_tests(files, functions, Keyword.get(config, :test_hints, []))

    result = %{
      base: base,
      changed_files: files,
      changed_functions: functions,
      suggested_tests: tests
    }

    render_result(result, opts[:format], &render_changed_text/1)
  end

  defp changed_files(base) do
    case System.cmd("git", ["diff", "--name-only", base <> "...HEAD"], stderr_to_stdout: true) do
      {output, 0} -> output |> String.split("\n", trim: true) |> Enum.reject(&(&1 == ""))
      {output, _} -> Mix.raise("Could not read changed files against #{base}: #{output}")
    end
  end

  defp changed_ranges(base) do
    case System.cmd("git", ["diff", "--unified=0", base <> "...HEAD"], stderr_to_stdout: true) do
      {output, 0} -> parse_diff_ranges(output)
      {output, _} -> Mix.raise("Could not read changed ranges against #{base}: #{output}")
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
          range = parse_hunk_range(line)
          {file, Map.update(acc, file, [range], &[range | &1])}

        true ->
          {file, acc}
      end
    end)
    |> elem(1)
    |> Map.new(fn {file, ranges} -> {file, Enum.reverse(ranges)} end)
  end

  defp parse_hunk_range(line) do
    case Regex.run(~r/\+(\d+)(?:,(\d+))?/, line) do
      [_, start] -> {String.to_integer(start), String.to_integer(start)}
      [_, start, count] -> range_from_count(String.to_integer(start), String.to_integer(count))
    end
  end

  defp range_from_count(start, 0), do: {start, start}
  defp range_from_count(start, count), do: {start, start + count - 1}

  defp changed_functions(project, changed_ranges) do
    changed_ranges
    |> Enum.flat_map(fn {file, ranges} ->
      ranges
      |> Enum.flat_map(fn {first, last} -> first..last end)
      |> Enum.map(&Project.find_function_at_location(project, file, &1))
      |> Enum.reject(&is_nil/1)
    end)
    |> Enum.uniq_by(&{&1.meta[:module], &1.meta[:name], &1.meta[:arity]})
    |> Enum.map(&function_summary(project, &1))
    |> Enum.sort_by(&{&1.file || "", &1.line || 0, &1.id})
  end

  defp function_summary(project, func) do
    id = {func.meta[:module], func.meta[:name], func.meta[:arity]}
    direct_callers = Project.callers(project, id, 1)

    %{
      id: Format.func_id_to_string(id),
      file: func.source_span && func.source_span.file,
      line: func.source_span && func.source_span.start_line,
      effects: Enum.map(function_effects(func), &to_string/1),
      direct_callers: Enum.map(direct_callers, &Format.func_id_to_string(&1.id)),
      direct_caller_count: length(direct_callers)
    }
  end

  defp suggested_tests(files, functions, hints) do
    hint_tests =
      hints
      |> Enum.flat_map(fn {pattern, tests} ->
        if Enum.any?(files, &glob_match?(&1, to_string(pattern))), do: tests, else: []
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

  defp test_paths_for_source(nil), do: []

  defp test_paths_for_source(file) do
    cond do
      String.starts_with?(file, "lib/mix/tasks/") ->
        task = file |> Path.basename(".ex") |> String.replace(".", "_")
        ["test/#{task}_test.exs", "test/mix_task_#{String.replace(task, "reach_", "")}_test.exs"]

      String.starts_with?(file, "lib/") ->
        base = file |> String.replace_prefix("lib/", "") |> Path.rootname()
        ["test/#{base}_test.exs"]

      true ->
        []
    end
  end

  defp render_candidates_placeholder(opts) do
    project = Project.load()
    config = if File.exists?(".reach.exs"), do: load_config(), else: []

    candidates =
      (cycle_candidates(project) ++
         mixed_effect_candidates(project) ++
         boundary_candidates(project, config))
      |> Enum.uniq_by(& &1.id)
      |> Enum.sort_by(&candidate_rank/1)

    result = %{
      candidates: candidates,
      note:
        "Candidates are advisory. Reach reports graph/effect/architecture evidence; prove behavior preservation before editing."
    }

    render_result(result, opts[:format], &render_candidates_text/1)
  end

  defp candidate_rank(candidate) do
    risk_rank = %{high: 0, medium: 1, low: 2}
    benefit_rank = %{high: 0, medium: 1, low: 2}

    {Map.get(risk_rank, candidate.risk, 3), Map.get(benefit_rank, candidate.benefit, 3),
     candidate.id}
  end

  defp cycle_candidates(project) do
    deps = module_dependency_map(project)

    deps
    |> Map.keys()
    |> Enum.flat_map(&walk_module_cycle(deps, &1, &1, [], 5))
    |> Enum.map(&canonical_module_cycle/1)
    |> Enum.uniq()
    |> Enum.take(20)
    |> Enum.with_index(1)
    |> Enum.map(fn {cycle, index} ->
      %{
        id: candidate_id("R3", index),
        kind: "break_cycle",
        target: Enum.join(cycle, " -> "),
        benefit: :high,
        risk: :medium,
        evidence: ["module_dependency_cycle"],
        suggestion:
          "Move shared code to a lower-level module or route calls through an existing boundary.",
        modules: cycle
      }
    end)
  end

  defp module_dependency_map(project) do
    modules =
      project.nodes
      |> Map.values()
      |> Enum.filter(&(&1.type == :module_def))
      |> MapSet.new(& &1.meta[:name])

    module_by_file = module_by_file(project)

    project.nodes
    |> Map.values()
    |> Enum.filter(&remote_call?/1)
    |> Enum.reduce(%{}, fn node, acc ->
      caller = node.source_span && Map.get(module_by_file, node.source_span.file)
      callee = node.meta[:module]

      if caller && callee && caller != callee && MapSet.member?(modules, callee) do
        Map.update(acc, caller, MapSet.new([callee]), &MapSet.put(&1, callee))
      else
        acc
      end
    end)
    |> Map.new(fn {module, deps} -> {module, MapSet.to_list(deps)} end)
  end

  defp walk_module_cycle(_deps, _start, _current, path, max) when length(path) >= max, do: []

  defp walk_module_cycle(deps, start, current, path, max) do
    deps
    |> Map.get(current, [])
    |> Enum.flat_map(fn next ->
      cond do
        next == start and path != [] -> [Enum.reverse([current | path])]
        next in path -> []
        true -> walk_module_cycle(deps, start, next, [current | path], max)
      end
    end)
  end

  defp canonical_module_cycle(cycle) do
    cycle
    |> Enum.map(&inspect/1)
    |> Enum.sort()
  end

  defp mixed_effect_candidates(project) do
    project.nodes
    |> Map.values()
    |> Enum.filter(&(&1.type == :function_def and &1.source_span))
    |> Enum.map(fn func -> {func, function_effects(func) -- [:pure]} end)
    |> Enum.filter(fn {_func, effects} -> length(effects) >= 2 end)
    |> Enum.sort_by(fn {func, effects} ->
      {-length(effects), func.source_span.file, func.source_span.start_line}
    end)
    |> Enum.take(20)
    |> Enum.with_index(1)
    |> Enum.map(fn {{func, effects}, index} ->
      id = {func.meta[:module], func.meta[:name], func.meta[:arity]}

      %{
        id: candidate_id("R2", index),
        kind: "isolate_effects",
        target: Format.func_id_to_string(id),
        file: func.source_span.file,
        line: func.source_span.start_line,
        benefit: :medium,
        risk: :medium,
        evidence: ["mixed_effects"],
        effects: Enum.map(effects, &to_string/1),
        suggestion:
          "Split pure decision logic from side-effect execution while preserving effect order."
      }
    end)
  end

  defp boundary_candidates(_project, []), do: []

  defp boundary_candidates(project, config) do
    layer_graph = layer_graph(project, config)

    dependency_violations(project, config, layer_graph)
    |> Enum.take(20)
    |> Enum.with_index(1)
    |> Enum.map(fn {violation, index} ->
      %{
        id: candidate_id("R5", index),
        kind: "introduce_boundary",
        target: "#{violation.caller_layer} -> #{violation.callee_layer}",
        file: violation.file,
        line: violation.line,
        benefit: :high,
        risk: :medium,
        evidence: ["architecture_policy_violation", "forbidden_dependency"],
        call: violation.call,
        suggestion:
          "Route this call through an allowed boundary or move the helper to an allowed lower layer."
      }
    end)
  end

  defp candidate_id(prefix, index),
    do: "#{prefix}-#{String.pad_leading(to_string(index), 3, "0")}"

  defp delegated_args(opts, positional) do
    []
    |> maybe_put("--format", opts[:format])
    |> maybe_put("--path", opts[:path])
    |> Kernel.++(positional)
  end

  defp maybe_put(args, _flag, nil), do: args
  defp maybe_put(args, flag, value), do: args ++ [flag, to_string(value)]

  defp render_candidates_text(%{candidates: []}) do
    IO.puts("No refactoring candidates found.")
  end

  defp render_candidates_text(%{candidates: candidates, note: note}) do
    IO.puts("Refactoring candidates (#{length(candidates)})")
    IO.puts(note)
    IO.puts("")

    Enum.each(candidates, fn candidate ->
      IO.puts("#{candidate.id} #{candidate.kind} #{candidate.target}")
      IO.puts("  benefit=#{candidate.benefit} risk=#{candidate.risk}")

      if candidate[:file] do
        IO.puts("  location=#{candidate.file}:#{candidate.line}")
      end

      IO.puts("  evidence=#{Enum.join(candidate.evidence, ",")}")
      IO.puts("  suggestion=#{candidate.suggestion}")
      IO.puts("")
    end)
  end

  defp render_result(result, "json", _text_fun) do
    ensure_json_encoder!()
    IO.puts(Jason.encode!(result, pretty: true))
  end

  defp render_result(result, _format, text_fun), do: text_fun.(result)

  defp render_arch_text(%{violations: []}) do
    IO.puts("Architecture policy: OK")
  end

  defp render_arch_text(%{violations: violations}) do
    IO.puts("Architecture policy: #{length(violations)} violation(s)")

    Enum.each(violations, fn
      %{type: "forbidden_dependency"} = violation ->
        IO.puts(
          "  #{violation.file}:#{violation.line} #{violation.caller_layer} -> #{violation.callee_layer} " <>
            "#{violation.call}"
        )

      %{type: "layer_cycle"} = violation ->
        IO.puts("  layer cycle: #{Enum.join(violation.layers, " -> ")}")

      %{type: "effect_policy"} = violation ->
        IO.puts(
          "  #{violation.file}:#{violation.line} #{violation.module}.#{violation.function} disallowed effects: " <>
            Enum.join(violation.disallowed_effects, ", ")
        )
    end)
  end

  defp render_changed_text(result) do
    IO.puts("Changed files against #{result.base}:")

    Enum.each(result.changed_files, fn file ->
      IO.puts("  #{file}")
    end)

    if result.changed_functions != [] do
      IO.puts("\nChanged functions:")

      Enum.each(result.changed_functions, fn function ->
        IO.puts(
          "  #{function.id} #{function.file}:#{function.line} callers=#{function.direct_caller_count} effects=#{Enum.join(function.effects, ",")}"
        )
      end)
    end

    if result.suggested_tests != [] do
      IO.puts("\nSuggested tests:")
      Enum.each(result.suggested_tests, &IO.puts("  mix test #{&1}"))
    end
  end

  defp ensure_json_encoder! do
    unless Code.ensure_loaded?(Jason) do
      Mix.raise("Jason is required for JSON output. Add {:jason, \"~> 1.0\"} to your deps.")
    end
  end
end
