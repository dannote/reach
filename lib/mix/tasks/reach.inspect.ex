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

  alias Reach.CLI.BoxartGraph
  alias Reach.CLI.Format
  alias Reach.CLI.Project
  alias Reach.CLI.TaskRunner
  alias Reach.Inspect.{Candidates, Context, Data, Why}

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
    project = load_target_project(target, opts)
    {mfa, func} = resolve_function!(project, target)
    data = Data.summary(project, func, opts[:variable])
    direct_callers = Project.callers(project, mfa, 1)
    transitive_callers = Project.callers(project, mfa, opts[:depth] || 4)
    callees = Project.callees(project, mfa, opts[:depth] || 3)

    IO.puts(Format.header("Reach context: #{Format.func_id_to_string(mfa)}"))
    IO.puts("  location: #{format_location(Context.location(func))}")
    IO.puts("  effects: #{Format.effects_join(Context.effects(func))}")

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
    project = load_target_project(target, opts)
    {mfa, func} = resolve_function!(project, target)

    context =
      project
      |> Context.build(mfa, func, opts)
      |> format_context()
      |> Map.put(:command, "reach.inspect")

    IO.puts(Jason.encode!(json_envelope(context), pretty: true))
  end

  defp format_location(%{file: file, line: line}) when is_binary(file) and is_integer(line),
    do: Format.loc(file, line)

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
    location = if item.file && item.line, do: Format.loc(item.file, item.line), else: "unknown"
    "#{item.name} #{location}"
  end

  defp format_return_summary(item) do
    location = if item.file && item.line, do: Format.loc(item.file, item.line), else: "unknown"
    "#{item.kind} #{location}"
  end

  defp format_context(context) do
    %{
      target: Format.func_id_to_string(context.target),
      location: context.location,
      effects: context.effects,
      deps: %{
        callers: Enum.map(context.deps.callers, &format_call/1),
        callees: Enum.map(context.deps.callees, &format_callee/1)
      },
      impact: %{
        direct_callers: Enum.map(context.impact.direct_callers, &format_call/1),
        transitive_callers: Enum.map(context.impact.transitive_callers, &format_call/1)
      },
      data: context.data
    }
  end

  defp render_data_json(target, opts) do
    ensure_json_encoder!()
    project = load_target_project(target, opts)
    {mfa, func} = resolve_function!(project, target)

    IO.puts(
      Jason.encode!(
        json_envelope(%{
          command: "reach.inspect",
          target: Format.func_id_to_string(mfa),
          location: Context.location(func),
          data: Data.summary(project, func, opts[:variable])
        }),
        pretty: true
      )
    )
  end

  defp render_data_text(target, opts) do
    project = load_target_project(target, opts)
    {_mfa, func} = resolve_function!(project, target)
    summary = Data.summary(project, func, opts[:variable])

    IO.puts("Definitions:")
    Enum.each(summary.definitions, &IO.puts("  #{&1.name} #{Format.loc(&1.file, &1.line)}"))

    IO.puts("Uses:")
    Enum.each(summary.uses, &IO.puts("  #{&1.name} #{Format.loc(&1.file, &1.line)}"))

    IO.puts("Returns:")
    Enum.each(summary.returns, &IO.puts("  #{&1.kind} #{Format.loc(&1.file, &1.line)}"))
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
    if file && line, do: IO.puts("    #{Format.loc(file, line)}")
  end

  defp render_why_node(%{module: module, file: file, line: line}) do
    IO.puts("  #{Format.bright(module)}")
    if file && line, do: IO.puts("    #{Format.loc(file, line)}")
  end

  defp render_why_evidence(evidence) do
    IO.puts("  #{evidence.from} -> #{evidence.to}")
    IO.puts("    #{evidence.call} #{Format.loc(evidence.file, evidence.line)}")
    if evidence.source, do: IO.puts("    #{evidence.source}")
  end

  defp ensure_json_encoder_if_needed(opts) do
    if opts[:format] == "json", do: ensure_json_encoder!()
  end

  defp load_target_project(target, opts) do
    case Project.parse_file_line(target) do
      {file, _line} -> Project.load(paths: [file], quiet: opts[:format] == "json")
      nil -> Project.load(quiet: opts[:format] == "json")
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

  defp format_call(%{id: id}), do: Format.func_id_to_string(id)

  defp format_callee(%{id: id, depth: depth, children: children}) do
    %{
      id: Format.func_id_to_string(id),
      depth: depth,
      children: Enum.map(children, &format_callee/1)
    }
  end

  defp render_candidates_placeholder(target, opts) do
    project = load_target_project(target, opts)
    {mfa, func} = resolve_function!(project, target)

    candidates =
      Enum.map(
        Candidates.find(project, mfa, func),
        &Map.put(&1, :target, Format.func_id_to_string(mfa))
      )

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

      IO.puts("  location=#{Format.loc(candidate.file, candidate.line)}")
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
