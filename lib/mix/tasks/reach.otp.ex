defmodule Mix.Tasks.Reach.Otp do
  @moduledoc """
  Shows GenServer state machines, missing message handlers, and hidden coupling.

      mix reach.otp
      mix reach.otp UserWorker
      mix reach.otp --format json

  ## Options

    * `--format` — output format: `text` (default), `json`, `oneline`
    * `--concurrency` — show Task/monitor/spawn and supervisor topology
    * `--state` — focus on state-machine output (accepted for canonical CLI compatibility)
    * `--messages` — focus on message-handler output (accepted for canonical CLI compatibility)
    * `--supervision` — focus on supervision output (accepted for canonical CLI compatibility)

  """

  use Mix.Task

  @shortdoc "Show OTP state machine analysis"

  @switches [
    format: :string,
    graph: :boolean,
    concurrency: :boolean,
    state: :boolean,
    messages: :boolean,
    supervision: :boolean
  ]
  @aliases [f: :format]

  alias Reach.CLI.Analyses.Concurrency
  alias Reach.CLI.BoxartGraph
  alias Reach.CLI.Format
  alias Reach.CLI.Pipe
  alias Reach.CLI.Project
  alias Reach.OTP.Analysis, as: OTPAnalysis

  @impl Mix.Task
  def run(args) do
    Pipe.safely(fn -> run_safe(args) end)
  end

  defp run_safe(args) do
    {opts, target_args, _} = OptionParser.parse(args, switches: @switches, aliases: @aliases)
    format = opts[:format] || "text"

    if opts[:concurrency] do
      Concurrency.run(concurrency_args(args), command: "reach.otp")
    else
      {project, scope} = load_project_and_scope(target_args, opts)
      result = analyze(project, scope)
      render_result(result, format, opts)
    end
  end

  defp render_result(result, "json", _opts),
    do: Format.render(result, "reach.otp", format: "json", pretty: true)

  defp render_result(result, "oneline", _opts), do: render_oneline(result)
  defp render_result(result, _format, opts), do: render_text(result, opts)

  defp concurrency_args(args) do
    Enum.reject(args, &(&1 == "--concurrency"))
  end

  defp load_project_and_scope([target | _rest], opts) do
    if File.exists?(target) do
      {Project.load(paths: [target], quiet: opts[:format] == "json"), nil}
    else
      {Project.load(quiet: opts[:format] == "json"), target}
    end
  end

  defp load_project_and_scope([], opts), do: {Project.load(quiet: opts[:format] == "json"), nil}

  defp analyze(project, scope), do: OTPAnalysis.run(project, scope)

  defp render_text(result, opts) do
    graph_mode = opts[:graph] || false

    if graph_mode, do: BoxartGraph.require!()

    IO.puts(Format.header("OTP Analysis"))

    if result.behaviours == [] and result.state_machines == [] do
      IO.puts("  " <> Format.empty("no OTP behaviours detected"))
      IO.puts("")
    else
      Enum.each(result.behaviours, &render_behaviour(&1, graph_mode))
      Enum.each(result.state_machines, &render_state_machine/1)
    end

    render_ets_coupling(result.hidden_coupling.ets)
    render_pdict_coupling(result.hidden_coupling.process_dict)
    render_missing_handlers(result.missing_handlers)
    render_dead_replies(result.dead_replies)
    render_cross_process(result.cross_process)
    render_supervision(result.supervision)
  end

  defp render_behaviour(gs, graph_mode) do
    IO.puts(
      Format.section(
        "#{format_module_or_path(gs.module)} #{Format.faint("(" <> gs.behaviour <> ")")}"
      )
    )

    if graph_mode do
      BoxartGraph.render_otp_state_diagram(gs.state_transforms)
    end

    IO.puts("  Callbacks:")

    if gs.state_transforms == [] do
      IO.puts("    " <> Format.empty())
    end

    gs.state_transforms
    |> Enum.sort_by(fn t -> t.callback end)
    |> Enum.each(fn t ->
      {name, arity} = t.callback

      IO.puts(
        "    #{Format.bright("#{name}/#{arity}")}  #{action_label(t.action)}  #{Format.location_text(t.location)}"
      )
    end)
  end

  defp format_module_or_path(module) when is_binary(module), do: Format.path(module)
  defp format_module_or_path(module), do: inspect(module)

  defp render_ets_coupling(ets) do
    tables = Enum.reject(ets, fn {k, _} -> k == :unknown_table end)

    if tables != [] do
      IO.puts(Format.section("Hidden coupling (ETS)"))
      Enum.each(tables, fn {table, ops} -> render_ops_group(":#{table}", ops) end)
    end
  end

  defp render_pdict_coupling(pdict) do
    keys = Enum.reject(pdict, fn {k, _} -> k == :unknown_key end)

    if keys != [] do
      IO.puts(Format.section("Process dictionary"))
      Enum.each(keys, fn {key, ops} -> render_ops_group(":#{key}", ops) end)
    end
  end

  defp render_ops_group(label, ops) do
    IO.puts("  #{label}")
    Enum.each(ops, fn op -> IO.puts("    #{op.action}  #{Format.location_text(op.location)}") end)
  end

  defp render_missing_handlers(handlers) do
    if handlers != [] do
      IO.puts(Format.section("Potentially unmatched messages"))

      Enum.each(handlers, fn h ->
        IO.puts(
          "  #{Format.location_text(h.location)}  #{Format.warning("#{h.message} to unknown handler")}"
        )
      end)
    end
  end

  defp render_dead_replies([]), do: :ok

  defp render_dead_replies(dead_replies) do
    IO.puts(Format.section("Dead GenServer replies"))

    Enum.each(dead_replies, fn dr ->
      target = if dr.target, do: " to #{inspect(dr.target)}", else: ""

      IO.puts(
        "  #{Format.location_text(dr.location)}  #{Format.warning("GenServer.call#{target} reply discarded")}"
      )
    end)
  end

  defp render_cross_process([]), do: :ok

  defp render_cross_process(findings) do
    IO.puts(Format.section("Cross-process coupling"))

    Enum.each(findings, fn f ->
      resource_label = format_resource(f.resource)

      IO.puts(
        "  #{Format.location_text(f.location)}  #{inspect(f.caller)} → #{inspect(f.callee)}"
      )

      IO.puts("    #{Format.warning("shared #{resource_label}")}")
    end)
  end

  defp format_resource({:ets, table}), do: "ETS :#{table}"
  defp format_resource({:pdict, key}), do: "process dict :#{key}"

  defp render_supervision(supervision) do
    if supervision != [] do
      IO.puts(Format.section("Supervision tree"))

      Enum.each(supervision, &render_supervisor/1)
    end
  end

  defp render_supervisor(s) do
    IO.puts(
      "  #{Format.bright(format_module_or_path(s.module))}  #{Format.location_text(s.location)}"
    )

    Enum.each(s.children, fn child -> IO.puts("    └─ #{inspect(child)}") end)
  end

  defp action_label(:writes), do: Format.red("writes state")
  defp action_label(:read_write), do: Format.yellow("read+write")
  defp action_label(:reads), do: Format.green("reads state")
  defp action_label(:passes_through), do: Format.faint("passes through")
  defp action_label(:unknown), do: Format.faint("no state access")

  defp render_state_machine(sm) do
    mode_label = Format.humanize(sm.callback_mode)

    IO.puts(
      Format.section(
        "#{format_module_or_path(sm.module)} #{Format.faint("(gen_statem, #{mode_label})")}"
      )
    )

    render_init_state(sm.init_state)
    render_statem_states(sm.states)
    render_statem_transitions(sm.transitions)
  end

  defp render_init_state(nil), do: :ok

  defp render_init_state(states) when is_list(states) do
    labels = Enum.map_join(states, " | ", &Format.bright(to_string(&1)))
    IO.puts("  Initial state: #{labels}")
  end

  defp render_init_state(state),
    do: IO.puts("  Initial state: #{Format.bright(to_string(state))}")

  defp render_statem_states(states) do
    IO.puts("  States:")

    states
    |> Enum.sort_by(fn {name, _} -> to_string(name) end)
    |> Enum.each(fn {state_name, info} ->
      event_types = info.events |> Enum.map(& &1.event_type) |> Enum.uniq()
      events_str = Enum.map_join(event_types, ", ", &format_event_type/1)
      IO.puts("    #{Format.bright(to_string(state_name))}  #{Format.faint(events_str)}")
    end)
  end

  defp render_statem_transitions([]), do: :ok

  defp render_statem_transitions(transitions) do
    IO.puts("  Transitions:")

    transitions
    |> Enum.uniq_by(fn t -> {t.from, t.to} end)
    |> Enum.sort_by(fn t -> {to_string(t.from), to_string(t.to)} end)
    |> Enum.each(fn t ->
      trigger = if t.trigger, do: " #{Format.faint(format_event_type(t.trigger))}", else: ""
      IO.puts("    #{to_string(t.from)} → #{Format.bright(to_string(t.to))}#{trigger}")
    end)
  end

  defp format_event_type(:cast), do: "cast"
  defp format_event_type(:info), do: "info"
  defp format_event_type(:internal), do: "internal"
  defp format_event_type(:any), do: "*"
  defp format_event_type(:unknown), do: "?"
  defp format_event_type({:call, _}), do: "call"
  defp format_event_type({:timeout, name}), do: "timeout:#{name}"
  defp format_event_type(other), do: to_string(other)

  defp render_oneline(result) do
    Enum.each(result.behaviours, fn gs ->
      Enum.each(gs.state_transforms, fn t ->
        {name, arity} = t.callback
        IO.puts("#{gs.module} #{name}/#{arity} #{t.action} #{t.location}")
      end)
    end)

    Enum.each(result.state_machines, fn sm ->
      Enum.each(sm.transitions, fn t ->
        IO.puts("#{sm.module} #{t.from}→#{t.to} #{format_event_type(t.trigger || :unknown)}")
      end)
    end)

    Enum.each(result.missing_handlers, fn h ->
      IO.puts("unmatched:#{h.location}:#{h.message}")
    end)

    Enum.each(result.dead_replies, fn dr ->
      target = if dr.target, do: inspect(dr.target), else: "?"
      IO.puts("dead_reply:#{dr.location}:#{target}")
    end)

    Enum.each(result.cross_process, fn f ->
      IO.puts(
        "coupling:#{f.location}:#{inspect(f.caller)}→#{inspect(f.callee)}:#{format_resource(f.resource)}"
      )
    end)
  end
end
