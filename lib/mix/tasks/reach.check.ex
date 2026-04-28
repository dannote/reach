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

  alias Reach.Analysis
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
        render_candidates_placeholder(opts)

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
    config_errors = config_violations(config)

    violations =
      if config_errors != [] do
        config_errors
      else
        project = Project.load()
        layer_graph = layer_graph(project, config)

        dependency_violations(project, config, layer_graph) ++
          public_boundary_violations(project, config) ++
          layer_cycle_violations(layer_graph) ++
          effect_policy_violations(project, config)
      end

    result = %{
      config: ".reach.exs",
      status: if(violations == [], do: "ok", else: "failed"),
      violations: violations
    }

    render_result(result, opts[:format], &render_arch_text/1)

    if violations != [] do
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

  @known_config_keys [
    :layers,
    :forbidden_deps,
    :allowed_effects,
    :public_api,
    :internal,
    :internal_callers,
    :test_hints
  ]

  defp config_violations(config) do
    unknown_key_violations(config) ++
      config_shape_violations(config)
  end

  defp unknown_key_violations(config) do
    config
    |> Keyword.keys()
    |> Enum.reject(&(&1 in @known_config_keys))
    |> Enum.map(fn key ->
      %{
        type: "config_error",
        key: to_string(key),
        message: "Unknown .reach.exs key #{inspect(key)}"
      }
    end)
  end

  defp config_shape_violations(config) do
    []
    |> config_check(config, :layers, &valid_layers?/1, "expected keyword list of layer: patterns")
    |> config_check(
      config,
      :forbidden_deps,
      &valid_forbidden_deps?/1,
      "expected list of {from_layer, to_layer}"
    )
    |> config_check(
      config,
      :allowed_effects,
      &valid_allowed_effects?/1,
      "expected list of {module_pattern, effects}"
    )
    |> config_check(
      config,
      :public_api,
      &valid_pattern_list?/1,
      "expected string or list of module patterns"
    )
    |> config_check(
      config,
      :internal,
      &valid_pattern_list?/1,
      "expected string or list of module patterns"
    )
    |> config_check(
      config,
      :internal_callers,
      &valid_internal_callers?/1,
      "expected list of {internal_pattern, caller_patterns}"
    )
    |> config_check(
      config,
      :test_hints,
      &valid_test_hints?/1,
      "expected list of {path_glob, test_paths}"
    )
  end

  defp config_check(violations, config, key, validator, message) do
    if Keyword.has_key?(config, key) and not validator.(Keyword.get(config, key)) do
      [%{type: "config_error", key: to_string(key), message: message} | violations]
    else
      violations
    end
  end

  defp valid_layers?(value) when is_list(value) do
    Enum.all?(value, fn
      {layer, patterns} when is_atom(layer) -> valid_pattern_list?(patterns)
      _ -> false
    end)
  end

  defp valid_layers?(_), do: false

  defp valid_forbidden_deps?(value) when is_list(value) do
    Enum.all?(value, fn
      {from, to} when is_atom(from) and is_atom(to) -> true
      _ -> false
    end)
  end

  defp valid_forbidden_deps?(_), do: false

  defp valid_allowed_effects?(value) when is_list(value) do
    Enum.all?(value, fn
      {pattern, effects} when is_binary(pattern) and is_list(effects) ->
        Enum.all?(effects, &is_atom/1)

      _ ->
        false
    end)
  end

  defp valid_allowed_effects?(_), do: false

  defp valid_pattern_list?(value) when is_binary(value), do: true
  defp valid_pattern_list?(value) when is_list(value), do: Enum.all?(value, &is_binary/1)
  defp valid_pattern_list?(_), do: false

  defp valid_internal_callers?(value) when is_list(value) do
    Enum.all?(value, fn
      {internal_pattern, caller_patterns} when is_binary(internal_pattern) ->
        valid_pattern_list?(caller_patterns)

      _ ->
        false
    end)
  end

  defp valid_internal_callers?(_), do: false

  defp valid_test_hints?(value) when is_list(value) do
    Enum.all?(value, fn
      {pattern, tests} when is_binary(pattern) and is_list(tests) ->
        Enum.all?(tests, &is_binary/1)

      _ ->
        false
    end)
  end

  defp valid_test_hints?(_), do: false

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

  defp public_boundary_violations(project, config) do
    public_api = Keyword.get(config, :public_api, []) |> List.wrap()
    internal = Keyword.get(config, :internal, []) |> List.wrap()
    internal_callers = Keyword.get(config, :internal_callers, [])
    module_by_file = module_by_file(project)

    project.nodes
    |> Map.values()
    |> Enum.filter(&remote_call?/1)
    |> Enum.flat_map(fn node ->
      caller = node.source_span && Map.get(module_by_file, node.source_span.file)
      callee = node.meta[:module]

      cond do
        caller == nil or callee == nil ->
          []

        public_api != [] and top_level_api_call?(caller, callee, public_api, internal) ->
          [
            %{
              type: "public_api_boundary",
              caller_module: inspect(caller),
              callee_module: inspect(callee),
              file: node.source_span.file,
              line: node.source_span.start_line,
              call: "#{inspect(callee)}.#{node.meta[:function]}/#{node.meta[:arity]}",
              rule: "calls into non-public API module"
            }
          ]

        internal != [] and internal_call_violation?(caller, callee, internal, internal_callers) ->
          [
            %{
              type: "internal_boundary",
              caller_module: inspect(caller),
              callee_module: inspect(callee),
              file: node.source_span.file,
              line: node.source_span.start_line,
              call: "#{inspect(callee)}.#{node.meta[:function]}/#{node.meta[:arity]}",
              rule: "caller is not allowed to call configured internal module"
            }
          ]

        true ->
          []
      end
    end)
  end

  defp top_level_api_call?(caller, callee, public_api, internal) do
    public_api
    |> Enum.map(&public_api_namespace/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.any?(fn namespace ->
      module_under_namespace?(callee, namespace) and
        not module_under_namespace?(caller, namespace) and
        not module_matches_any?(callee, public_api) and
        not module_matches_any?(callee, internal)
    end)
  end

  defp internal_call_violation?(caller, callee, internal, internal_callers) do
    module_matches_any?(callee, internal) and
      not allowed_internal_caller?(caller, callee, internal_callers)
  end

  defp allowed_internal_caller?(caller, callee, internal_callers) do
    matching_rule =
      Enum.find(internal_callers, fn {internal_pattern, _caller_patterns} ->
        module_matches_any?(callee, [internal_pattern])
      end)

    case matching_rule do
      {_internal_pattern, caller_patterns} ->
        module_matches_any?(caller, List.wrap(caller_patterns))

      nil ->
        module_namespace(caller) == module_namespace(callee)
    end
  end

  defp public_api_namespace(pattern) do
    pattern
    |> to_string()
    |> String.replace_suffix(".*", "")
    |> String.trim_trailing("*")
    |> String.trim_trailing(".")
    |> case do
      "" -> nil
      namespace -> namespace
    end
  end

  defp module_under_namespace?(module, namespace) do
    name = module_name(module)
    name == namespace or String.starts_with?(name, namespace <> ".")
  end

  defp module_namespace(module) do
    module
    |> module_name()
    |> String.split(".")
    |> List.first()
  end

  defp module_name(module) do
    module
    |> Atom.to_string()
    |> String.replace_leading("Elixir.", "")
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
    module_by_file = module_by_file(project)

    project.nodes
    |> Map.values()
    |> Enum.filter(&(&1.type == :function_def))
    |> Enum.flat_map(&effect_policy_violation(&1, policies, module_by_file))
  end

  defp effect_policy_violation(func, policies, module_by_file) do
    module =
      func.meta[:module] || (func.source_span && Map.get(module_by_file, func.source_span.file))

    with allowed when not is_nil(allowed) <- allowed_effects_for(module, policies),
         effects <- function_effects(func),
         disallowed when disallowed != [] <- effects -- allowed do
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
    else
      _ -> []
    end
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

  defp concrete_effects(func), do: function_effects(func) -- [:pure, :unknown, :exception]

  defp remote_call?(node) do
    node.type == :call and node.meta[:kind] == :remote and node.meta[:module] != nil and
      node.meta[:function] not in [:__aliases__, :{}]
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
    base = opts[:base] || default_base_ref()
    config = if File.exists?(".reach.exs"), do: load_config(), else: []
    project = Project.load()
    files = changed_files(base)
    changed_ranges = changed_ranges(base)
    functions = changed_functions(project, changed_ranges, config)
    tests = suggested_tests(files, functions, Keyword.get(config, :test_hints, []))

    {risk, risk_reasons} = aggregate_change_risk(functions)

    result = %{
      base: base,
      risk: risk,
      risk_reasons: risk_reasons,
      changed_files: files,
      changed_functions: functions,
      public_api_changes: Enum.filter(functions, & &1.public_api),
      suggested_tests: tests
    }

    render_result(result, opts[:format], &render_changed_text/1)
  end

  defp default_base_ref do
    cond do
      git_ref?("main") -> "main"
      git_ref?("master") -> "master"
      upstream = git_upstream() -> upstream
      true -> "HEAD"
    end
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

  defp changed_functions(project, changed_ranges, config) do
    changed_ranges
    |> Enum.flat_map(fn {file, ranges} ->
      ranges
      |> Enum.flat_map(fn {first, last} -> first..last end)
      |> Enum.map(&Project.find_function_at_location(project, file, &1))
      |> Enum.reject(&is_nil/1)
    end)
    |> Enum.uniq_by(&{&1.meta[:module], &1.meta[:name], &1.meta[:arity]})
    |> Enum.map(&function_summary(project, &1, config))
    |> Enum.sort_by(&{&1.file || "", &1.line || 0, &1.id})
  end

  defp function_summary(project, func, config) do
    id = {func.meta[:module], func.meta[:name], func.meta[:arity]}
    direct_callers = Project.callers(project, id, 1)
    transitive_callers = Project.callers(project, id, 4)
    effects = function_effects(func)
    branches = branch_count(func)
    {risk, reasons} = change_risk(func, direct_callers, transitive_callers, effects, branches)

    %{
      id: Format.func_id_to_string(id),
      file: func.source_span && func.source_span.file,
      line: func.source_span && func.source_span.start_line,
      risk: risk,
      risk_reasons: reasons,
      public_api: public_api_function?(func, config),
      effects: Enum.map(effects, &to_string/1),
      branch_count: branches,
      direct_callers: Enum.map(direct_callers, &Format.func_id_to_string(&1.id)),
      direct_caller_count: length(direct_callers),
      transitive_caller_count: length(transitive_callers)
    }
  end

  defp aggregate_change_risk([]), do: {:low, []}

  defp aggregate_change_risk(functions) do
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

  defp public_api_function?(func, config) do
    func.meta[:kind] in [:def, :defmacro] and
      module_matches_any?(func.meta[:module], Keyword.get(config, :public_api, []) |> List.wrap())
  end

  defp change_risk(func, direct_callers, transitive_callers, effects, branches) do
    reasons =
      []
      |> maybe_reason(length(direct_callers) >= 5, "many direct callers")
      |> maybe_reason(length(transitive_callers) >= 10, "wide transitive impact")
      |> maybe_reason(branches >= 8, "branch-heavy function")
      |> maybe_reason(multiple?(effects -- [:pure]), "mixed side effects")
      |> maybe_reason(core_module?(func.meta[:module]), "core Reach module")

    risk =
      cond do
        at_least_three?(reasons) -> :high
        reasons != [] -> :medium
        true -> :low
      end

    {risk, reasons}
  end

  defp at_least_three?([_, _, _ | _]), do: true
  defp at_least_three?(_reasons), do: false

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

  defp branch_count(func) do
    func
    |> IR.all_nodes()
    |> Enum.count(
      &(&1.type in [:case, :receive, :try] or
          (&1.type == :binary_op and &1.meta[:operator] in [:and, :or, :&&, :||]))
    )
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
      (mixed_effect_candidates(project) ++
         extract_region_candidates(project) ++
         boundary_candidates(project, config) ++
         cycle_candidates(project))
      |> Enum.uniq_by(& &1.id)
      |> Enum.sort_by(&candidate_rank/1)
      |> Enum.take(opts[:top] || 40)

    result = %{
      candidates: candidates,
      note:
        "Candidates are advisory. Reach reports graph/effect/architecture evidence; prove behavior preservation before editing."
    }

    render_result(result, opts[:format], &render_candidates_text/1)
  end

  defp candidate_rank(candidate) do
    kind_rank = %{
      "introduce_boundary" => 0,
      "isolate_effects" => 1,
      "extract_pure_region" => 2,
      "break_cycle" => 3
    }

    risk_rank = %{high: 0, medium: 1, low: 2}
    benefit_rank = %{high: 0, medium: 1, low: 2}

    {
      Map.get(kind_rank, candidate.kind, 9),
      Map.get(risk_rank, candidate.risk, 3),
      Map.get(benefit_rank, candidate.benefit, 3),
      candidate.id
    }
  end

  defp cycle_candidates(project) do
    deps = module_dependency_map(project)
    call_examples = module_call_examples(project)

    deps
    |> Map.keys()
    |> Enum.flat_map(&walk_module_cycle(deps, &1, &1, [], 5))
    |> Enum.map(&canonical_module_cycle/1)
    |> Enum.uniq()
    |> minimal_cycles()
    |> Enum.take(20)
    |> Enum.with_index(1)
    |> Enum.map(fn {cycle, index} ->
      %{
        id: candidate_id("R3", index),
        kind: "break_cycle",
        target: Enum.join(cycle, " -> "),
        benefit: :high,
        risk: :medium,
        confidence: :low,
        actionability: :needs_project_policy,
        evidence: ["module_dependency_cycle"],
        proof: [
          "Confirm the cycle violates intended architecture before changing code.",
          "Review representative_calls to find the smallest boundary-breaking call.",
          "Prefer moving shared helpers downward over introducing a new abstraction."
        ],
        suggestion:
          "Move shared code to a lower-level module or route calls through an existing boundary.",
        modules: cycle,
        representative_calls: representative_cycle_calls(cycle, call_examples)
      }
    end)
  end

  defp module_dependency_map(project) do
    project
    |> module_call_edges()
    |> Enum.reduce(%{}, fn edge, acc ->
      Map.update(acc, edge.caller, MapSet.new([edge.callee]), &MapSet.put(&1, edge.callee))
    end)
    |> Map.new(fn {module, deps} -> {module, MapSet.to_list(deps)} end)
  end

  defp module_call_examples(project) do
    project
    |> module_call_edges()
    |> Enum.group_by(&{inspect(&1.caller), inspect(&1.callee)})
    |> Map.new(fn {key, edges} ->
      {key, Enum.take(edges, 3) |> Enum.map(&representative_call/1)}
    end)
  end

  defp module_call_edges(project) do
    modules =
      project.nodes
      |> Map.values()
      |> Enum.filter(&(&1.type == :module_def))
      |> MapSet.new(& &1.meta[:name])

    module_by_file = module_by_file(project)

    project.nodes
    |> Map.values()
    |> Enum.filter(&remote_call?/1)
    |> Enum.flat_map(fn node ->
      caller = node.source_span && Map.get(module_by_file, node.source_span.file)
      callee = node.meta[:module]

      if caller && callee && caller != callee && MapSet.member?(modules, callee) do
        [%{caller: caller, callee: callee, node: node}]
      else
        []
      end
    end)
  end

  defp representative_cycle_calls(cycle, call_examples) do
    cycle
    |> cycle_pairs()
    |> Enum.flat_map(&Map.get(call_examples, &1, []))
    |> Enum.take(10)
  end

  defp cycle_pairs(cycle) do
    cycle
    |> Enum.zip(tl(cycle) ++ [hd(cycle)])
    |> Enum.flat_map(fn {left, right} -> [{left, right}, {right, left}] end)
    |> Enum.uniq()
  end

  defp representative_call(%{caller: caller, callee: callee, node: node}) do
    %{
      caller_module: inspect(caller),
      callee_module: inspect(callee),
      file: node.source_span && node.source_span.file,
      line: node.source_span && node.source_span.start_line,
      call: "#{inspect(callee)}.#{node.meta[:function]}/#{node.meta[:arity]}"
    }
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

  defp minimal_cycles(cycles) do
    sorted = Enum.sort_by(cycles, &length/1)

    Enum.reduce(sorted, [], fn cycle, kept ->
      cycle_set = MapSet.new(cycle)

      if Enum.any?(kept, &MapSet.subset?(MapSet.new(&1), cycle_set)) do
        kept
      else
        kept ++ [cycle]
      end
    end)
  end

  defp mixed_effect_candidates(project) do
    project.nodes
    |> Map.values()
    |> Enum.filter(&(&1.type == :function_def and &1.source_span))
    |> Enum.reject(&Analysis.expected_effect_boundary?/1)
    |> Enum.map(fn func -> {func, concrete_effects(func)} end)
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
        confidence: :medium,
        actionability: :review_effect_order,
        evidence: ["mixed_effects"],
        effects: Enum.map(effects, &to_string/1),
        proof: [
          "Preserve side-effect order exactly.",
          "Extract only pure decision/preparation code first.",
          "Run tests covering both success and error paths."
        ],
        suggestion:
          "Split pure decision logic from side-effect execution while preserving effect order."
      }
    end)
  end

  defp extract_region_candidates(project) do
    project.nodes
    |> Map.values()
    |> Enum.filter(&(&1.type == :function_def and &1.source_span))
    |> Enum.map(fn func ->
      {func, branch_count(func), Project.callers(project, function_id(func), 1)}
    end)
    |> Enum.filter(fn {_func, branches, callers} -> branches >= 8 and callers != [] end)
    |> Enum.reject(fn {func, _branches, _callers} ->
      Analysis.expected_effect_boundary?(func) and branch_count(func) < 20
    end)
    |> Enum.sort_by(fn {func, branches, callers} ->
      {-branches * max(length(callers), 1), func.source_span.file, func.source_span.start_line}
    end)
    |> Enum.take(20)
    |> Enum.with_index(1)
    |> Enum.map(fn {{func, branches, callers}, index} ->
      %{
        id: candidate_id("R1", index),
        kind: "extract_pure_region",
        target: Format.func_id_to_string(function_id(func)),
        file: func.source_span.file,
        line: func.source_span.start_line,
        benefit: :medium,
        risk: if(length(callers) > 3, do: :high, else: :medium),
        confidence: :medium,
        actionability: :needs_region_proof,
        evidence: ["branchy_function", "caller_impact"],
        branches: branches,
        direct_caller_count: length(callers),
        proof: [
          "Identify a single-entry/single-exit region before editing.",
          "Verify extracted region has explicit inputs and one clear output.",
          "Add or run fixture tests around behavior and source spans."
        ],
        suggestion:
          "Look for a single-entry/single-exit pure branch region before extracting. Do not extract by size alone."
      }
    end)
  end

  defp function_id(func), do: {func.meta[:module], func.meta[:name], func.meta[:arity]}

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
        confidence: :high,
        actionability: :policy_violation,
        evidence: ["architecture_policy_violation", "forbidden_dependency"],
        call: violation.call,
        proof: [
          "Verify the .reach.exs policy matches the intended architecture.",
          "Route through an existing boundary when possible.",
          "Avoid making internal modules public just to silence the violation."
        ],
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

      IO.puts(
        "  benefit=#{candidate.benefit} risk=#{candidate.risk} confidence=#{candidate[:confidence] || :unknown}"
      )

      if candidate[:file] do
        IO.puts("  location=#{candidate.file}:#{candidate.line}")
      end

      IO.puts("  evidence=#{Enum.join(candidate.evidence, ",")}")

      render_representative_calls(candidate)

      IO.puts("  suggestion=#{candidate.suggestion}")
      IO.puts("")
    end)
  end

  defp render_representative_calls(%{representative_calls: calls}) when calls != [] do
    IO.puts("  representative calls:")

    Enum.each(calls, fn call ->
      IO.puts("    #{call.file}:#{call.line} #{call.caller_module} -> #{call.call}")
    end)
  end

  defp render_representative_calls(_candidate), do: :ok

  defp render_result(result, "json", _text_fun) do
    ensure_json_encoder!()
    IO.puts(Jason.encode!(Map.put_new(result, :command, "reach.check"), pretty: true))
  end

  defp render_result(result, _format, text_fun), do: text_fun.(result)

  defp render_arch_text(%{violations: []}) do
    IO.puts("Architecture policy: OK")
  end

  defp render_arch_text(%{violations: violations}) do
    IO.puts("Architecture policy: #{length(violations)} violation(s)")

    Enum.each(violations, fn
      %{type: "config_error"} = violation ->
        IO.puts("  config #{violation.key}: #{violation.message}")

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

      %{type: type} = violation when type in ["public_api_boundary", "internal_boundary"] ->
        IO.puts(
          "  #{violation.file}:#{violation.line} #{violation.caller_module} -> #{violation.callee_module} #{violation.call} (#{violation.rule})"
        )
    end)
  end

  defp render_changed_text(result) do
    IO.puts("Changed files against #{result.base}:")
    IO.puts("Overall risk: #{result.risk}")

    if result.risk_reasons != [] do
      IO.puts("Risk reasons: #{Enum.join(result.risk_reasons, ", ")}")
    end

    Enum.each(result.changed_files, fn file ->
      IO.puts("  #{file}")
    end)

    if result.changed_functions != [] do
      IO.puts("\nChanged functions:")

      Enum.each(result.changed_functions, fn function ->
        IO.puts(
          "  #{function.id} #{function.file}:#{function.line} risk=#{function.risk} callers=#{function.direct_caller_count}/#{function.transitive_caller_count} branches=#{function.branch_count} effects=#{Enum.join(function.effects, ",")}"
        )
      end)
    end

    if result.public_api_changes != [] do
      IO.puts("\nPublic API touched:")
      Enum.each(result.public_api_changes, &IO.puts("  #{&1.id} #{&1.file}:#{&1.line}"))
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
