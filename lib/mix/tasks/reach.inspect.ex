defmodule Mix.Tasks.Reach.Inspect do
  @moduledoc """
  Explains one function, module, file, or line.

      mix reach.inspect Reach.Frontend.Elixir.translate/3
      mix reach.inspect lib/reach/frontend/elixir.ex:54
      mix reach.inspect TARGET --deps
      mix reach.inspect TARGET --impact
      mix reach.inspect TARGET --slice
      mix reach.inspect TARGET --graph
      mix reach.inspect TARGET --call-graph
      mix reach.inspect TARGET --data
      mix reach.inspect TARGET --context
      mix reach.inspect TARGET --candidates
      mix reach.inspect TARGET --why OTHER

  ## Options

    * `--format` — output format passed to delegated analyses: `text`, `json`, `oneline`
    * `--deps` — callers, callees, and shared state
    * `--impact` — direct/transitive change impact
    * `--slice` — backward program slice
    * `--forward` — use a forward slice with `--slice` or `--data`
    * `--graph` — render graph output where supported
    * `--call-graph` — render the call graph around the target
    * `--data` — target-local data-flow view
    * `--context` — agent-readable bundle: deps, impact, data, effects
    * `--candidates` — advisory placeholder for graph-backed refactoring candidates
    * `--why` — explain the shortest graph-backed relationship to another target
    * `--depth` — transitive depth passed to deps/impact
    * `--variable` — variable filter passed to slice/data views
    * `--limit` — text display limit for truncated context sections
    * `--all` — show all text rows in context output

  """

  use Mix.Task

  alias Reach.Analysis
  alias Reach.CLI.BoxartGraph
  alias Reach.CLI.Format
  alias Reach.CLI.Project
  alias Reach.CLI.TaskRunner
  alias Reach.Effects
  alias Reach.Inspect.Why
  alias Reach.IR

  @shortdoc "Inspect one target's dependencies, impact, slices, and context"

  @switches [
    format: :string,
    deps: :boolean,
    impact: :boolean,
    slice: :boolean,
    forward: :boolean,
    graph: :boolean,
    call_graph: :boolean,
    data: :boolean,
    context: :boolean,
    candidates: :boolean,
    why: :string,
    depth: :integer,
    variable: :string,
    limit: :integer,
    all: :boolean
  ]

  @aliases [f: :format]

  @impl Mix.Task
  def run(args) do
    {opts, target_args, _} = OptionParser.parse(args, switches: @switches, aliases: @aliases)

    target =
      List.first(target_args) || Mix.raise("Expected a target. Usage: mix reach.inspect TARGET")

    run_action(inspect_action(opts), target, target_args, opts)
  end

  defp inspect_action(opts) do
    [
      {opts[:context], :context},
      {opts[:why] != nil, :why},
      {opts[:candidates], :candidates},
      {opts[:impact], :impact},
      {opts[:deps], :deps},
      {opts[:data] == true and opts[:format] == "json", :data_json},
      {opts[:data] == true and opts[:graph] != true, :data_text},
      {opts[:slice] == true or opts[:data] == true, :slice},
      {opts[:call_graph], :call_graph},
      {opts[:graph], :graph}
    ]
    |> Enum.find_value(:context, fn
      {true, action} -> action
      {_enabled, _action} -> nil
    end)
  end

  defp run_action(:context, target, _target_args, opts), do: run_context(target, opts)

  defp run_action(:why, target, _target_args, opts), do: render_why(target, opts)

  defp run_action(:candidates, target, _target_args, opts),
    do: render_candidates_placeholder(target, opts)

  defp run_action(:impact, target, _target_args, opts),
    do:
      TaskRunner.run("reach.impact", target_args(target, opts, graph?: opts[:graph]),
        command: "reach.inspect"
      )

  defp run_action(:deps, target, _target_args, opts),
    do:
      TaskRunner.run("reach.deps", target_args(target, opts, graph?: opts[:graph]),
        command: "reach.inspect"
      )

  defp run_action(:call_graph, target, _target_args, opts),
    do:
      TaskRunner.run("reach.deps", target_args(target, opts, graph?: true),
        command: "reach.inspect"
      )

  defp run_action(:graph, target, _target_args, opts), do: render_cfg(target, opts)
  defp run_action(:data_json, target, _target_args, opts), do: render_data_json(target, opts)
  defp run_action(:data_text, target, _target_args, opts), do: render_data_text(target, opts)

  defp run_action(:slice, target, _target_args, opts),
    do: TaskRunner.run("reach.slice", slice_args(target, opts), command: "reach.inspect")

  defp render_why(target, opts) do
    ensure_json_encoder_if_needed(opts)
    project = Project.load(quiet: opts[:format] == "json")
    result = why_result(project, target, opts[:why], opts[:depth] || 6)

    if opts[:format] == "json" do
      IO.puts(Jason.encode!(json_envelope(result), pretty: true))
    else
      render_why_text(result)
    end
  end

  defp run_context(target, opts) do
    if opts[:format] == "json" do
      render_context_json(target, opts)
    else
      render_context_text(target, opts)
    end
  end

  defp render_context_text(target, opts) do
    project = Project.load()
    {mfa, func} = resolve_function!(project, target)
    data = data_summary(project, func, opts[:variable])
    direct_callers = Project.callers(project, mfa, 1)
    transitive_callers = Project.callers(project, mfa, opts[:depth] || 4)
    callees = Project.callees(project, mfa, opts[:depth] || 3)

    IO.puts(Format.header("Reach context: #{Format.func_id_to_string(mfa)}"))
    IO.puts("  location: #{format_location(location(func))}")
    IO.puts("  effects: #{Enum.join(effects(func), ", ")}")

    IO.puts(
      "  callers: #{length(direct_callers)} direct, #{length(transitive_callers)} transitive"
    )

    IO.puts(
      "  data: #{length(data.definitions)} definitions, #{length(data.uses)} uses, #{length(data.returns)} returns"
    )

    IO.puts(Format.section("Callers"))

    render_limited(
      Enum.map(direct_callers, &format_call/1),
      display_limit(opts),
      &IO.puts("  #{&1}")
    )

    IO.puts(Format.section("Callees"))

    render_limited(
      Enum.map(callees, &format_callee_line/1),
      display_limit(opts),
      &IO.puts("  #{&1}")
    )

    IO.puts(Format.section("Definitions"))

    render_limited(
      Enum.map(data.definitions, &format_var_summary/1),
      display_limit(opts),
      &IO.puts("  #{&1}")
    )

    IO.puts(Format.section("Uses"))

    render_limited(
      Enum.map(data.uses, &format_var_summary/1),
      display_limit(opts),
      &IO.puts("  #{&1}")
    )

    IO.puts(Format.section("Returns"))

    render_limited(
      Enum.map(data.returns, &format_return_summary/1),
      display_limit(opts),
      &IO.puts("  #{&1}")
    )
  end

  defp render_context_json(target, opts) do
    ensure_json_encoder!()
    project = Project.load(quiet: opts[:format] == "json")
    {mfa, func} = resolve_function!(project, target)
    depth = opts[:depth] || 3

    context = %{
      command: "reach.inspect",
      target: Format.func_id_to_string(mfa),
      location: location(func),
      effects: effects(func),
      deps: %{
        callers: Project.callers(project, mfa, 1) |> Enum.map(&format_call/1),
        callees: Project.callees(project, mfa, depth) |> Enum.map(&format_callee/1)
      },
      impact: %{
        direct_callers: Project.callers(project, mfa, 1) |> Enum.map(&format_call/1),
        transitive_callers:
          Project.callers(project, mfa, opts[:depth] || 4) |> Enum.map(&format_call/1)
      },
      data: data_summary(project, func, opts[:variable])
    }

    IO.puts(Jason.encode!(json_envelope(context), pretty: true))
  end

  defp format_location(%{file: file, line: line}) when is_binary(file) and is_integer(line),
    do: "#{file}:#{line}"

  defp format_location(_location), do: "unknown"

  defp display_limit(opts) do
    cond do
      opts[:all] -> :all
      is_integer(opts[:limit]) and opts[:limit] > 0 -> opts[:limit]
      true -> 20
    end
  end

  defp render_limited(items, :all, render_fun) do
    Enum.each(items, render_fun)
  end

  defp render_limited(items, limit, render_fun) do
    shown = Enum.take(items, limit)
    Enum.each(shown, render_fun)

    remaining = length(items) - length(shown)

    if remaining > 0 do
      IO.puts("  ... #{remaining} more omitted. Use --limit N, --all, or --format json.")
    end
  end

  defp format_callee_line(%{id: id, depth: depth}) do
    String.duplicate("  ", depth - 1) <> Format.func_id_to_string(id)
  end

  defp format_var_summary(item) do
    location = if item.file && item.line, do: "#{item.file}:#{item.line}", else: "unknown"
    "#{item.name} #{Format.faint(location)}"
  end

  defp format_return_summary(item) do
    location = if item.file && item.line, do: "#{item.file}:#{item.line}", else: "unknown"
    "#{item.kind} #{Format.faint(location)}"
  end

  defp render_data_json(target, opts) do
    ensure_json_encoder!()
    project = Project.load(quiet: opts[:format] == "json")
    {mfa, func} = resolve_function!(project, target)

    IO.puts(
      Jason.encode!(
        json_envelope(%{
          command: "reach.inspect",
          target: Format.func_id_to_string(mfa),
          location: location(func),
          data: data_summary(project, func, opts[:variable])
        }),
        pretty: true
      )
    )
  end

  defp render_data_text(target, opts) do
    project = Project.load(quiet: opts[:format] == "json")
    {_mfa, func} = resolve_function!(project, target)
    summary = data_summary(project, func, opts[:variable])

    IO.puts("Definitions:")
    Enum.each(summary.definitions, &IO.puts("  #{&1.name} #{&1.file}:#{&1.line}"))

    IO.puts("Uses:")
    Enum.each(summary.uses, &IO.puts("  #{&1.name} #{&1.file}:#{&1.line}"))

    IO.puts("Returns:")
    Enum.each(summary.returns, &IO.puts("  #{&1.kind} #{&1.file}:#{&1.line}"))
  end

  defp render_cfg(target, opts) do
    BoxartGraph.require!()

    {{_mod, fun, arity}, func} = resolve_graph_target!(target, opts)
    file = func.source_span && func.source_span.file

    IO.puts(Format.header("#{fun}/#{arity}"))

    if file do
      BoxartGraph.render_cfg(func, file)
    else
      IO.puts("  (no source file available)")
    end
  end

  defp resolve_graph_target!(target, opts) do
    case Project.parse_file_line(target) do
      {file, line} ->
        project = Project.load(paths: [file], quiet: opts[:format] == "json")
        func = Project.find_function_at_location(project, file, line)

        if func do
          {{func.meta[:module], func.meta[:name], func.meta[:arity]}, func}
        else
          Mix.raise("Function not found: #{target}")
        end

      nil ->
        project = Project.load(quiet: opts[:format] == "json")
        resolve_function!(project, target)
    end
  end

  defp why_result(project, source_raw, target_raw, max_depth),
    do: Why.result(project, source_raw, target_raw, max_depth)

  defp render_why_text(%{paths: []} = result) do
    IO.puts(Format.header("Why #{result.target} -> #{result.why}"))

    message =
      case result[:reason] do
        nil -> "No #{result.relation} found."
        "source_not_found" -> "Source target could not be resolved."
        "target_not_found" -> "Why target could not be resolved."
        reason -> "No relationship found (#{reason})."
      end

    IO.puts("  #{message}")
  end

  defp render_why_text(result) do
    IO.puts(Format.header("Why #{result.target} -> #{result.why}"))
    IO.puts("Relation: #{result.relation}")

    Enum.each(result.paths, fn path ->
      IO.puts(Format.section("Path"))
      Enum.each(path.nodes, &render_why_node/1)

      if path.evidence != [] do
        IO.puts(Format.section("Evidence"))
        Enum.each(path.evidence, &render_why_evidence/1)
      end
    end)
  end

  defp render_why_node(%{function: function, file: file, line: line}) do
    IO.puts("  #{Format.bright(function)}")
    if file && line, do: IO.puts("    #{Format.faint("#{file}:#{line}")}")
  end

  defp render_why_node(%{module: module, file: file, line: line}) do
    IO.puts("  #{Format.bright(module)}")
    if file && line, do: IO.puts("    #{Format.faint("#{file}:#{line}")}")
  end

  defp render_why_evidence(evidence) do
    IO.puts("  #{evidence.from} -> #{evidence.to}")
    IO.puts("    #{evidence.call} #{Format.faint("#{evidence.file}:#{evidence.line}")}")
    if evidence.source, do: IO.puts("    #{evidence.source}")
  end

  defp ensure_json_encoder_if_needed(opts) do
    if opts[:format] == "json", do: ensure_json_encoder!()
  end

  defp resolve_function!(project, raw) do
    case Project.parse_file_line(raw) do
      {file, line} ->
        func =
          Project.find_function_at_location(project, file, line) ||
            Mix.raise("Function not found at #{raw}")

        {{func.meta[:module], func.meta[:name], func.meta[:arity]}, func}

      nil ->
        mfa = Project.resolve_target(project, raw) || Mix.raise("Function not found: #{raw}")

        func =
          Project.find_function(project, mfa) ||
            Mix.raise("Function definition not found in IR: #{raw}")

        {mfa, func}
    end
  end

  defp data_summary(project, func, variable) do
    nodes = IR.all_nodes(func)
    node_ids = MapSet.new(nodes, & &1.id)
    nodes_by_id = Map.new(nodes, &{&1.id, &1})

    vars =
      Enum.filter(nodes, fn node ->
        node.type == :var and (variable == nil or to_string(node.meta[:name]) == variable)
      end)

    %{
      definitions:
        vars |> Enum.filter(&(&1.meta[:binding_role] == :definition)) |> Enum.map(&var_summary/1),
      uses:
        vars |> Enum.reject(&(&1.meta[:binding_role] == :definition)) |> Enum.map(&var_summary/1),
      returns: return_summaries(func),
      edges: data_edges(project, node_ids, nodes_by_id, variable)
    }
  end

  defp data_edges(project, node_ids, nodes_by_id, variable) do
    project.graph
    |> Graph.edges()
    |> Enum.filter(fn edge ->
      Analysis.data_edge?(edge) and MapSet.member?(node_ids, edge.v1) and
        MapSet.member?(node_ids, edge.v2) and
        (variable == nil or to_string(data_edge_label(edge)) == variable)
    end)
    |> Enum.take(200)
    |> Enum.map(fn edge ->
      %{
        from: Map.get(nodes_by_id, edge.v1) |> compact_node_summary(),
        to: Map.get(nodes_by_id, edge.v2) |> compact_node_summary(),
        label: inspect(edge.label)
      }
    end)
  end

  defp data_edge_label(%Graph.Edge{label: {:data, var}}), do: var
  defp data_edge_label(%Graph.Edge{label: label}), do: label

  defp return_summaries(func) do
    func.children
    |> List.wrap()
    |> Enum.flat_map(&clause_return/1)
  end

  defp clause_return(%{type: :clause, children: children}) do
    children
    |> List.wrap()
    |> List.last()
    |> case do
      nil -> []
      node -> [node_summary(node)]
    end
  end

  defp clause_return(node), do: [node_summary(node)]

  defp var_summary(node) do
    span = node.source_span || %{}

    %{
      name: to_string(node.meta[:name]),
      role: to_string(node.meta[:binding_role] || "use"),
      file: span[:file],
      line: span[:start_line]
    }
  end

  defp node_summary(node) do
    span = node.source_span || %{}

    %{
      kind: to_string(node.type),
      file: span[:file],
      line: span[:start_line]
    }
  end

  defp compact_node_summary(nil), do: nil

  defp compact_node_summary(node) do
    span = node.source_span || %{}

    %{
      id: node.id,
      kind: to_string(node.type),
      name: compact_node_name(node),
      file: span[:file],
      line: span[:start_line]
    }
  end

  defp compact_node_name(%{type: :var, meta: meta}), do: meta[:name] && to_string(meta[:name])
  defp compact_node_name(%{type: :call, meta: meta}), do: call_name(meta)
  defp compact_node_name(%{meta: meta}), do: meta[:name] && to_string(meta[:name])

  defp call_name(meta) do
    if meta[:module] do
      "#{inspect(meta[:module])}.#{meta[:function]}/#{meta[:arity]}"
    else
      "#{meta[:function]}/#{meta[:arity]}"
    end
  end

  defp effects(func) do
    func
    |> IR.all_nodes()
    |> Enum.map(&Effects.classify/1)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(&to_string/1)
  end

  defp location(func) do
    span = func.source_span || %{}
    %{file: span[:file], line: span[:start_line]}
  end

  defp format_call(%{id: id}), do: Format.func_id_to_string(id)

  defp format_callee(%{id: id, depth: depth, children: children}) do
    %{
      id: Format.func_id_to_string(id),
      depth: depth,
      children: Enum.map(children, &format_callee/1)
    }
  end

  defp render_candidates_placeholder(target, opts) do
    project = Project.load(quiet: opts[:format] == "json")
    {mfa, func} = resolve_function!(project, target)
    candidates = target_candidates(project, mfa, func)

    result = %{
      command: "reach.inspect",
      target: Format.func_id_to_string(mfa),
      candidates: candidates,
      note: "Candidates are advisory. Prove behavior preservation before editing."
    }

    case opts[:format] do
      "json" ->
        ensure_json_encoder!()
        IO.puts(Jason.encode!(json_envelope(result), pretty: true))

      _ ->
        render_candidates_text(result)
    end
  end

  defp target_candidates(project, mfa, func) do
    non_pure_effects = function_effect_atoms(func) -- [:pure, :unknown, :exception]
    callers = Project.callers(project, mfa, 1)
    branch_count = branch_count(func)

    []
    |> maybe_candidate(isolate_effects_candidate(mfa, func, non_pure_effects))
    |> maybe_candidate(extract_region_candidate(mfa, func, branch_count, callers))
  end

  defp isolate_effects_candidate(mfa, func, effects) do
    cond do
      length(effects) < 2 ->
        nil

      Analysis.expected_effect_boundary?(func) ->
        nil

      true ->
        %{
          id: "R2-001",
          kind: "isolate_effects",
          target: Format.func_id_to_string(mfa),
          file: func.source_span && func.source_span.file,
          line: func.source_span && func.source_span.start_line,
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
    end
  end

  defp extract_region_candidate(_mfa, _func, branch_count, _callers) when branch_count < 4,
    do: nil

  defp extract_region_candidate(mfa, func, branch_count, callers) do
    %{
      id: "R1-001",
      kind: "extract_pure_region",
      target: Format.func_id_to_string(mfa),
      file: func.source_span && func.source_span.file,
      line: func.source_span && func.source_span.start_line,
      benefit: :medium,
      risk: if(length(callers) > 3, do: :high, else: :medium),
      confidence: :medium,
      actionability: :needs_region_proof,
      evidence: ["branchy_function", "caller_impact"],
      branches: branch_count,
      direct_caller_count: length(callers),
      proof: [
        "Identify a single-entry/single-exit region before editing.",
        "Verify extracted region has explicit inputs and one clear output.",
        "Add or run fixture tests around behavior and source spans."
      ],
      suggestion:
        "Look for a single-entry/single-exit pure branch region before extracting. Do not extract by size alone."
    }
  end

  defp maybe_candidate(candidates, nil), do: candidates
  defp maybe_candidate(candidates, candidate), do: candidates ++ [candidate]

  defp branch_count(func) do
    func
    |> IR.all_nodes()
    |> Enum.count(
      &(&1.type in [:case, :receive, :try] or
          (&1.type == :binary_op and &1.meta[:operator] in [:and, :or, :&&, :||]))
    )
  end

  defp function_effect_atoms(func) do
    func
    |> IR.all_nodes()
    |> Enum.map(&Effects.classify/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp render_candidates_text(%{target: target, candidates: []}) do
    IO.puts("Refactoring candidates for #{target}")
    IO.puts("")
    IO.puts("No graph-backed candidates found.")
  end

  defp render_candidates_text(%{target: target, candidates: candidates, note: note}) do
    IO.puts("Refactoring candidates for #{target}")
    IO.puts(note)
    IO.puts("")

    Enum.each(candidates, fn candidate ->
      IO.puts("#{candidate.id} #{candidate.kind}")

      IO.puts(
        "  benefit=#{candidate.benefit} risk=#{candidate.risk} confidence=#{candidate[:confidence] || :unknown}"
      )

      IO.puts("  location=#{candidate.file}:#{candidate.line}")
      IO.puts("  evidence=#{Enum.join(candidate.evidence, ",")}")
      IO.puts("  suggestion=#{candidate.suggestion}")
      IO.puts("")
    end)
  end

  defp target_args(target, opts, extra) do
    [target]
    |> maybe_put("--format", opts[:format])
    |> maybe_put("--depth", opts[:depth])
    |> maybe_flag("--graph", Keyword.get(extra, :graph?, false))
  end

  defp slice_args(target, opts) do
    [target]
    |> maybe_put("--format", opts[:format])
    |> maybe_put("--variable", opts[:variable])
    |> maybe_flag("--forward", opts[:forward])
    |> maybe_flag("--graph", opts[:graph])
  end

  defp maybe_put(args, _flag, nil), do: args
  defp maybe_put(args, flag, value), do: args ++ [flag, to_string(value)]

  defp maybe_flag(args, _flag, false), do: args
  defp maybe_flag(args, _flag, nil), do: args
  defp maybe_flag(args, flag, true), do: args ++ [flag]

  defp json_envelope(%{command: command} = data) do
    %Reach.CLI.JSONEnvelope{command: command, data: Map.delete(data, :command)}
  end

  defp ensure_json_encoder! do
    unless Code.ensure_loaded?(Jason) do
      Mix.raise("Jason is required for JSON output. Add {:jason, \"~> 1.0\"} to your deps.")
    end
  end
end
