defmodule Reach.CLI.Render.OTP do
  @moduledoc false

  alias Reach.CLI.BoxartGraph
  alias Reach.CLI.Format

  def render(result, "json", _opts),
    do: Format.render(result, "reach.otp", format: "json", pretty: true)

  def render(result, "oneline", _opts), do: render_oneline(result)
  def render(result, _format, opts), do: render_text(result, opts)

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

    if graph_mode, do: BoxartGraph.render_otp_state_diagram(gs.state_transforms)

    IO.puts("  Callbacks:")
    if gs.state_transforms == [], do: IO.puts("    " <> Format.empty())

    gs.state_transforms
    |> Enum.sort_by(fn transform -> transform.callback end)
    |> Enum.each(fn transform ->
      {name, arity} = transform.callback

      IO.puts(
        "    #{Format.bright("#{name}/#{arity}")}  #{action_label(transform.action)}  #{Format.location_text(transform.location)}"
      )
    end)
  end

  defp format_module_or_path(module) when is_binary(module), do: Format.path(module)
  defp format_module_or_path(module), do: inspect(module)

  defp render_ets_coupling(ets) do
    tables = Enum.reject(ets, fn {key, _ops} -> key == :unknown_table end)

    if tables != [] do
      IO.puts(Format.section("Hidden coupling (ETS)"))
      Enum.each(tables, fn {table, ops} -> render_ops_group(":#{table}", ops) end)
    end
  end

  defp render_pdict_coupling(pdict) do
    keys = Enum.reject(pdict, fn {key, _ops} -> key == :unknown_key end)

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

      Enum.each(handlers, fn handler ->
        IO.puts(
          "  #{Format.location_text(handler.location)}  #{Format.warning("#{handler.message} to unknown handler")}"
        )
      end)
    end
  end

  defp render_dead_replies([]), do: :ok

  defp render_dead_replies(dead_replies) do
    IO.puts(Format.section("Dead GenServer replies"))

    Enum.each(dead_replies, fn dead_reply ->
      target = if dead_reply.target, do: " to #{inspect(dead_reply.target)}", else: ""

      IO.puts(
        "  #{Format.location_text(dead_reply.location)}  #{Format.warning("GenServer.call#{target} reply discarded")}"
      )
    end)
  end

  defp render_cross_process([]), do: :ok

  defp render_cross_process(findings) do
    IO.puts(Format.section("Cross-process coupling"))

    Enum.each(findings, fn finding ->
      resource_label = format_resource(finding.resource)

      IO.puts(
        "  #{Format.location_text(finding.location)}  #{inspect(finding.caller)} → #{inspect(finding.callee)}"
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

  defp render_supervisor(supervisor) do
    IO.puts(
      "  #{Format.bright(format_module_or_path(supervisor.module))}  #{Format.location_text(supervisor.location)}"
    )

    Enum.each(supervisor.children, fn child -> IO.puts("    └─ #{inspect(child)}") end)
  end

  defp action_label(:writes), do: Format.red("writes state")
  defp action_label(:read_write), do: Format.yellow("read+write")
  defp action_label(:reads), do: Format.green("reads state")
  defp action_label(:passes_through), do: Format.faint("passes through")
  defp action_label(:unknown), do: Format.faint("no state access")

  defp render_state_machine(state_machine) do
    mode_label = Format.humanize(state_machine.callback_mode)

    IO.puts(
      Format.section(
        "#{format_module_or_path(state_machine.module)} #{Format.faint("(gen_statem, #{mode_label})")}"
      )
    )

    render_init_state(state_machine.init_state)
    render_statem_states(state_machine.states)
    render_statem_transitions(state_machine.transitions)
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
    |> Enum.sort_by(fn {name, _info} -> to_string(name) end)
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
    |> Enum.uniq_by(fn transition -> {transition.from, transition.to} end)
    |> Enum.sort_by(fn transition -> {to_string(transition.from), to_string(transition.to)} end)
    |> Enum.each(fn transition ->
      trigger =
        if transition.trigger,
          do: " #{Format.faint(format_event_type(transition.trigger))}",
          else: ""

      IO.puts(
        "    #{to_string(transition.from)} → #{Format.bright(to_string(transition.to))}#{trigger}"
      )
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
    Enum.each(result.behaviours, fn gen_server ->
      Enum.each(gen_server.state_transforms, fn transform ->
        {name, arity} = transform.callback
        IO.puts("#{gen_server.module} #{name}/#{arity} #{transform.action} #{transform.location}")
      end)
    end)

    Enum.each(result.state_machines, fn state_machine ->
      Enum.each(state_machine.transitions, fn transition ->
        IO.puts(
          "#{state_machine.module} #{transition.from}→#{transition.to} #{format_event_type(transition.trigger || :unknown)}"
        )
      end)
    end)

    Enum.each(result.missing_handlers, fn handler ->
      IO.puts("unmatched:#{handler.location}:#{handler.message}")
    end)

    Enum.each(result.dead_replies, fn dead_reply ->
      target = if dead_reply.target, do: inspect(dead_reply.target), else: "?"
      IO.puts("dead_reply:#{dead_reply.location}:#{target}")
    end)

    Enum.each(result.cross_process, fn finding ->
      IO.puts(
        "coupling:#{finding.location}:#{inspect(finding.caller)}→#{inspect(finding.callee)}:#{format_resource(finding.resource)}"
      )
    end)
  end
end
