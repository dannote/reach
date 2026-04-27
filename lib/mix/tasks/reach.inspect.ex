defmodule Mix.Tasks.Reach.Inspect do
  @moduledoc """
  Explains one function, module, file, or line.

      mix reach.inspect Reach.Frontend.Elixir.translate/3
      mix reach.inspect lib/reach/frontend/elixir.ex:54
      mix reach.inspect TARGET --deps
      mix reach.inspect TARGET --impact
      mix reach.inspect TARGET --slice
      mix reach.inspect TARGET --graph
      mix reach.inspect TARGET --data
      mix reach.inspect TARGET --context
      mix reach.inspect TARGET --candidates

  ## Options

    * `--format` — output format passed to delegated analyses: `text`, `json`, `oneline`
    * `--deps` — callers, callees, and shared state
    * `--impact` — direct/transitive change impact
    * `--slice` — backward program slice
    * `--forward` — use a forward slice with `--slice` or `--data`
    * `--graph` — render graph output where supported
    * `--data` — target-local data-flow view
    * `--context` — agent-readable bundle: deps, impact, data, effects
    * `--candidates` — advisory placeholder for graph-backed refactoring candidates
    * `--depth` — transitive depth passed to deps/impact
    * `--variable` — variable filter passed to slice/data views

  """

  use Mix.Task

  alias Reach.CLI.BoxartGraph
  alias Reach.CLI.Format
  alias Reach.CLI.Project
  alias Reach.CLI.TaskRunner
  alias Reach.Effects
  alias Reach.IR

  @shortdoc "Inspect one target's dependencies, impact, slices, and context"

  @switches [
    format: :string,
    deps: :boolean,
    impact: :boolean,
    slice: :boolean,
    forward: :boolean,
    graph: :boolean,
    data: :boolean,
    context: :boolean,
    candidates: :boolean,
    depth: :integer,
    variable: :string
  ]

  @aliases [f: :format]

  @impl Mix.Task
  def run(args) do
    {opts, target_args, _} = OptionParser.parse(args, switches: @switches, aliases: @aliases)

    target =
      List.first(target_args) || Mix.raise("Expected a target. Usage: mix reach.inspect TARGET")

    cond do
      opts[:context] ->
        run_context(target, opts)

      opts[:candidates] ->
        render_candidates_placeholder(target, opts)

      opts[:impact] ->
        TaskRunner.run("reach.impact", target_args(target, opts, graph?: opts[:graph]))

      opts[:deps] ->
        TaskRunner.run("reach.deps", target_args(target, opts, graph?: opts[:graph]))

      opts[:graph] ->
        render_cfg(target)

      opts[:data] and opts[:format] == "json" ->
        render_data_json(target, opts)

      opts[:slice] or opts[:data] ->
        TaskRunner.run("reach.slice", slice_args(target, opts))

      true ->
        run_context(target, opts)
    end
  end

  defp run_context(target, opts) do
    if opts[:format] == "json" do
      render_context_json(target, opts)
    else
      IO.puts("# Reach context for #{target}\n")
      IO.puts("## Dependencies\n")
      TaskRunner.run("reach.deps", target_args(target, opts))
      IO.puts("\n## Impact\n")
      TaskRunner.run("reach.impact", target_args(target, opts))
      IO.puts("\n## Data\n")
      render_data_text(target, opts)
    end
  end

  defp render_context_json(target, opts) do
    ensure_json_encoder!()
    project = Project.load()
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

    IO.puts(Jason.encode!(context, pretty: true))
  end

  defp render_data_json(target, opts) do
    ensure_json_encoder!()
    project = Project.load()
    {mfa, func} = resolve_function!(project, target)

    IO.puts(
      Jason.encode!(
        %{
          command: "reach.inspect",
          target: Format.func_id_to_string(mfa),
          location: location(func),
          data: data_summary(project, func, opts[:variable])
        },
        pretty: true
      )
    )
  end

  defp render_data_text(target, opts) do
    project = Project.load()
    {_mfa, func} = resolve_function!(project, target)
    summary = data_summary(project, func, opts[:variable])

    IO.puts("Definitions:")
    Enum.each(summary.definitions, &IO.puts("  #{&1.name} #{&1.file}:#{&1.line}"))

    IO.puts("Uses:")
    Enum.each(summary.uses, &IO.puts("  #{&1.name} #{&1.file}:#{&1.line}"))

    IO.puts("Returns:")
    Enum.each(summary.returns, &IO.puts("  #{&1.kind} #{&1.file}:#{&1.line}"))
  end

  defp render_cfg(target) do
    unless BoxartGraph.available?() do
      Mix.raise("boxart is required for --graph. Add {:boxart, \"~> 0.3\"} to your deps.")
    end

    project = Project.load()
    {{_mod, fun, arity}, func} = resolve_function!(project, target)
    file = func.source_span && func.source_span.file

    IO.puts(Format.header("#{fun}/#{arity}"))

    if file do
      BoxartGraph.render_cfg(func, file)
    else
      IO.puts("  (no source file available)")
    end
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
      nodes
      |> Enum.filter(&(&1.type == :var))
      |> Enum.filter(fn node -> variable == nil or to_string(node.meta[:name]) == variable end)

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
    |> Enum.filter(&data_edge?/1)
    |> Enum.filter(&(&1.v1 in node_ids and &1.v2 in node_ids))
    |> Enum.filter(fn edge ->
      variable == nil or to_string(data_edge_label(edge)) == variable
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

  defp data_edge?(%Graph.Edge{label: {:data, _}}), do: true

  defp data_edge?(%Graph.Edge{label: label})
       when label in [:parameter_in, :parameter_out, :summary], do: true

  defp data_edge?(_edge), do: false

  defp data_edge_label(%Graph.Edge{label: {:data, var}}), do: var
  defp data_edge_label(%Graph.Edge{label: label}), do: label

  defp return_summaries(func) do
    func.children
    |> List.wrap()
    |> Enum.map(&node_summary/1)
  end

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
    project = Project.load()
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
        IO.puts(Jason.encode!(result, pretty: true))

      _ ->
        render_candidates_text(result)
    end
  end

  defp target_candidates(project, mfa, func) do
    non_pure_effects = function_effect_atoms(func) -- [:pure, :unknown]
    callers = Project.callers(project, mfa, 1)
    branch_count = branch_count(func)

    []
    |> maybe_candidate(isolate_effects_candidate(mfa, func, non_pure_effects))
    |> maybe_candidate(extract_region_candidate(mfa, func, branch_count, callers))
  end

  defp isolate_effects_candidate(_mfa, _func, effects) when length(effects) < 2, do: nil

  defp isolate_effects_candidate(mfa, func, effects) do
    %{
      id: "R2-001",
      kind: "isolate_effects",
      target: Format.func_id_to_string(mfa),
      file: func.source_span && func.source_span.file,
      line: func.source_span && func.source_span.start_line,
      benefit: :medium,
      risk: :medium,
      evidence: ["mixed_effects"],
      effects: Enum.map(effects, &to_string/1),
      suggestion:
        "Split pure decision logic from side-effect execution while preserving effect order."
    }
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
      evidence: ["branchy_function", "caller_impact"],
      branches: branch_count,
      direct_caller_count: length(callers),
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
      IO.puts("  benefit=#{candidate.benefit} risk=#{candidate.risk}")
      IO.puts("  location=#{candidate.file}:#{candidate.line}")
      IO.puts("  evidence=#{Enum.join(candidate.evidence, ",")}")
      IO.puts("  suggestion=#{candidate.suggestion}")
      IO.puts("")
    end)
  end

  defp target_args(target, opts, extra \\ []) do
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

  defp ensure_json_encoder! do
    unless Code.ensure_loaded?(Jason) do
      Mix.raise("Jason is required for JSON output. Add {:jason, \"~> 1.0\"} to your deps.")
    end
  end
end
