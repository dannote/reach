defmodule Mix.Tasks.Reach.Otp do
  @moduledoc """
  Shows GenServer state machines, missing message handlers, and hidden coupling.

      mix reach.otp
      mix reach.otp UserWorker
      mix reach.otp --format json

  ## Options

    * `--format` — output format: `text` (default), `json`, `oneline`
    * `--concurrency` — delegate to `mix reach.concurrency`
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

  alias Reach.CLI.BoxartGraph
  alias Reach.CLI.Format
  alias Reach.CLI.Project
  alias Reach.CLI.TaskRunner
  alias Reach.IR
  alias Reach.OTP.CrossProcess
  alias Reach.OTP.DeadReply
  alias Reach.OTP.GenStatem

  @impl Mix.Task
  def run(args) do
    {opts, target_args, _} = OptionParser.parse(args, switches: @switches, aliases: @aliases)
    format = opts[:format] || "text"

    if opts[:concurrency] do
      TaskRunner.run("reach.concurrency", delegated_args(args), command: "reach.otp")
    else
      project = Project.load()
      scope = List.first(target_args)

      result = analyze(project, scope)

      case format do
        "json" -> Format.render(result, "reach.otp", format: "json", pretty: true)
        "oneline" -> render_oneline(result)
        _ -> render_text(result, opts)
      end
    end
  end

  defp delegated_args(args) do
    Enum.reject(args, &(&1 == "--concurrency"))
  end

  defp analyze(project, scope) do
    nodes = Map.values(project.nodes)
    all_ir = Enum.flat_map(nodes, &IR.all_nodes/1)

    behaviours = find_gen_servers(nodes, scope)
    state_machines = find_gen_statems(all_ir, scope)
    hidden_coupling = find_hidden_coupling(nodes)
    missing_handlers = find_missing_handlers(nodes)
    supervision = find_supervision(nodes)
    dead_replies = DeadReply.find_dead_replies(nodes, all_nodes: all_ir)
    cross_process = CrossProcess.find_cross_process_coupling(nodes, all_nodes: all_ir)

    %{
      behaviours: behaviours,
      state_machines: state_machines,
      hidden_coupling: hidden_coupling,
      missing_handlers: missing_handlers,
      supervision: supervision,
      dead_replies: dead_replies,
      cross_process: cross_process
    }
  end

  defp find_gen_servers(nodes, scope) do
    nodes
    |> Enum.filter(&(&1.type == :function_def))
    |> Enum.group_by(&module_key(&1, scope))
    |> Enum.reject(fn {mod, _} -> is_nil(mod) end)
    |> Enum.map(fn {mod, func_defs} ->
      callbacks = group_callbacks(func_defs)

      if map_size(callbacks) > 0 do
        state_transforms = analyze_state_transforms(callbacks)

        %{
          module: mod,
          behaviour: detect_behaviour(callbacks),
          callbacks: callbacks,
          state_transforms: state_transforms
        }
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp find_gen_statems(nodes, scope) do
    nodes
    |> Enum.filter(fn n ->
      n.type == :module_def and
        (!scope || (n.meta[:name] && to_string(n.meta[:name]) =~ scope))
    end)
    |> Enum.map(fn mod_node ->
      children = [mod_node | IR.all_nodes(mod_node)]
      analysis = GenStatem.analyze(children)

      if analysis do
        location = Format.location(mod_node)
        Map.merge(analysis, %{module: mod_node.meta[:name], location: location})
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp module_key(node, scope) do
    mod = node.meta[:module]
    file = if node.source_span, do: node.source_span[:file], else: nil
    key = mod || file

    cond do
      scope && key && to_string(key) =~ scope -> key
      scope -> nil
      true -> key
    end
  end

  defp group_callbacks(func_defs) do
    func_defs
    |> Enum.filter(fn n ->
      n.meta[:name] in [
        :init,
        :handle_call,
        :handle_cast,
        :handle_info,
        :handle_continue,
        :terminate,
        :code_change
      ]
    end)
    |> Map.new(fn n ->
      {{n.meta[:name], n.meta[:arity]}, n}
    end)
  end

  defp detect_behaviour(callbacks) do
    cond do
      Map.has_key?(callbacks, {:handle_call, 3}) -> "GenServer"
      Map.has_key?(callbacks, {:handle_event, 3}) -> "GenStage"
      Map.has_key?(callbacks, {:handle_demand, 2}) -> "GenStage"
      Map.has_key?(callbacks, {:init, 1}) -> "GenServer"
      true -> "unknown"
    end
  end

  defp analyze_state_transforms(callbacks) do
    callbacks
    |> Enum.filter(fn {{name, _}, _} ->
      name in [:init, :handle_call, :handle_cast, :handle_info, :handle_continue]
    end)
    |> Enum.map(fn {{name, arity}, node} ->
      state_param = find_state_param(node, arity)
      action = infer_state_action(node, state_param)

      %{
        callback: {name, arity},
        action: action,
        location: Format.location(node)
      }
    end)
  end

  defp find_state_param(node, arity) do
    node.children
    |> Enum.filter(&(&1.type == :clause))
    |> Enum.flat_map(fn clause ->
      clause.children |> Enum.take(arity) |> Enum.take(-1)
    end)
    |> Enum.map(&unwrap_state_param/1)
    |> Enum.reject(&is_nil/1)
    |> List.first()
  end

  defp unwrap_state_param(%{type: :match, children: children}) do
    # Prefer var over struct (e.g. %State{} = state → use :state)
    Enum.find(children, &(&1.type == :var)) ||
      Enum.find(children, &(&1.type in [:struct, :map])) ||
      Enum.find_value(children, &unwrap_state_param/1)
  end

  defp unwrap_state_param(%{type: t} = node) when t in [:var, :struct, :map], do: node
  defp unwrap_state_param(_), do: nil

  defp infer_state_action(_node, nil), do: :unknown

  defp infer_state_action(node, state_param) do
    state_name = state_param_name(state_param)
    all = IR.all_nodes(node)

    cond do
      writes_state?(all, state_name) -> :read_write
      reads_state?(all, state_name) -> :reads
      state_name != nil -> :passes_through
      true -> :unknown
    end
  end

  defp reads_state?(all, state_name) do
    field_access?(all, state_name) or state_passed_as_arg?(all, state_name)
  end

  defp field_access?(all, state_name) do
    Enum.any?(all, fn n ->
      n.type == :call and n.meta[:kind] == :remote and n.meta[:module] == state_name
    end)
  end

  defp state_passed_as_arg?(all, state_name) do
    Enum.any?(all, fn n ->
      n.type == :call and Enum.any?(n.children, &var_named?(&1, state_name))
    end)
  end

  defp writes_state?(all, state_name) do
    Enum.any?(all, fn n ->
      struct_or_map_update?(n, state_name) or
        map_write_call?(n, state_name) or
        ets_write_with_state?(n, state_name)
    end)
  end

  defp struct_or_map_update?(n, state_name) do
    n.type in [:struct, :map] and has_update_syntax?(n, state_name)
  end

  defp map_write_call?(n, state_name) do
    n.type == :call and
      n.meta[:function] in [:put, :update, :merge, :delete] and
      n.meta[:module] == Map and
      Enum.any?(n.children, &var_named?(&1, state_name))
  end

  defp ets_write_with_state?(n, state_name) do
    n.type == :call and
      n.meta[:module] == :ets and
      n.meta[:function] in [:insert, :insert_new, :update_element, :delete] and
      Enum.any?(n.children, &var_named?(&1, state_name))
  end

  defp state_param_name(%{type: :var, meta: %{name: name}}), do: name

  defp state_param_name(%{type: type, children: children}) when type in [:struct, :map] do
    case Enum.find(children, &(&1.type == :match)) do
      %{children: [_, %{type: :var, meta: %{name: name}}]} ->
        name

      _ ->
        case List.last(children) do
          %{type: :var, meta: %{name: name}} -> name
          _ -> nil
        end
    end
  end

  defp state_param_name(_), do: nil

  defp var_named?(%{type: :var, meta: %{name: name}}, target), do: name == target
  defp var_named?(_, _), do: false

  defp has_update_syntax?(%{children: children}, state_name) do
    case children do
      [%{type: :var, meta: %{name: ^state_name}} | _] -> true
      _ -> false
    end
  end

  defp find_hidden_coupling(nodes) do
    ets_ops = find_ets_ops(nodes)
    pdict_ops = find_pdict_ops(nodes)
    %{ets: ets_ops, process_dict: pdict_ops}
  end

  defp find_ets_ops(nodes) do
    nodes
    |> Enum.filter(fn n -> n.type == :call and n.meta[:module] == :ets end)
    |> Enum.map(fn n ->
      action = classify_ets_action(n.meta[:function])
      %{action: action, function: n.meta[:function], node: n, location: Format.location(n)}
    end)
    |> Enum.group_by(fn op ->
      case op.node.children do
        [%{type: :literal, meta: %{value: name}} | _] when is_atom(name) -> name
        _ -> :unknown_table
      end
    end)
  end

  defp classify_ets_action(func) do
    cond do
      func in [:insert, :insert_new, :delete] -> :write
      func in [:lookup, :lookup_element, :match, :select, :member] -> :read
      true -> :unknown
    end
  end

  defp find_pdict_ops(nodes) do
    nodes
    |> Enum.filter(fn n ->
      n.type == :call and n.meta[:module] == Process and
        n.meta[:function] in [:put, :get, :delete]
    end)
    |> Enum.map(fn n ->
      key =
        case n.children do
          [%{type: :literal, meta: %{value: k}} | _] -> k
          _ -> :unknown_key
        end

      %{
        key: key,
        action: if(n.meta[:function] in [:put, :delete], do: :write, else: :read),
        location: Format.location(n)
      }
    end)
    |> Enum.group_by(& &1.key)
  end

  defp find_missing_handlers(nodes) do
    sends = find_gen_server_sends(nodes)
    {handles, has_catch_all} = find_handled_messages(nodes)

    sends
    |> Enum.reject(fn n -> has_catch_all and not literal_atom_msg?(n) end)
    |> Enum.filter(&unmatched_send?(&1, handles))
    |> Enum.map(fn n ->
      %{location: Format.location(n), message: n.meta[:function]}
    end)
  end

  defp literal_atom_msg?(%{children: children}) do
    Enum.any?(children, fn
      %{type: :literal, meta: %{value: v}} when is_atom(v) -> true
      _ -> false
    end)
  end

  defp find_gen_server_sends(nodes) do
    Enum.filter(nodes, fn n ->
      n.type == :call and n.meta[:function] in [:cast, :call] and
        n.meta[:module] == GenServer
    end)
  end

  defp find_handled_messages(nodes) do
    handlers =
      nodes
      |> Enum.filter(fn n ->
        n.type == :function_def and n.meta[:name] in [:handle_call, :handle_cast, :handle_info]
      end)

    has_catch_all =
      Enum.any?(handlers, fn handler ->
        handler.children
        |> Enum.filter(&(&1.type == :clause))
        |> Enum.any?(&catch_all_clause?/1)
      end)

    handles =
      handlers
      |> Enum.flat_map(&extract_clause_message_types/1)
      |> MapSet.new()

    {handles, has_catch_all}
  end

  defp catch_all_clause?(clause) do
    case clause.children do
      [%{type: :var} | _] -> true
      _ -> false
    end
  end

  defp extract_clause_message_types(func) do
    func.children
    |> Enum.filter(&(&1.type == :clause))
    |> Enum.flat_map(&extract_message_patterns(&1, func.meta[:arity]))
  end

  defp extract_message_patterns(clause, arity) do
    clause.children
    |> Enum.take(arity)
    |> Enum.flat_map(fn
      %{type: :literal, meta: %{value: val}} when is_atom(val) ->
        [val]

      %{type: :tuple, children: children} ->
        children
        |> Enum.filter(&(&1.type == :literal))
        |> Enum.map(& &1.meta[:value])

      _ ->
        []
    end)
  end

  defp unmatched_send?(send_node, handles) do
    case send_node.children do
      [_mod_or_pid, %{type: :literal, meta: %{value: msg_type}} | _] ->
        msg_type not in handles

      [%{type: :literal, meta: %{value: msg_type}} | _] ->
        msg_type not in handles

      _ ->
        false
    end
  end

  defp find_supervision(nodes) do
    init_supervisors =
      nodes
      |> Enum.filter(fn n ->
        n.type == :function_def and n.meta[:name] == :init and n.meta[:arity] == 1 and
          supervisor_init?(n)
      end)
      |> Enum.map(fn n ->
        children = extract_supervisor_children(n)
        %{module: n.meta[:module], location: Format.location(n), children: children}
      end)

    inline_supervisors =
      nodes
      |> Enum.filter(fn n ->
        n.type == :call and n.meta[:module] == Supervisor and
          n.meta[:function] == :start_link
      end)
      |> Enum.map(fn n ->
        parent = find_containing_function(nodes, n.id)
        children = if parent, do: extract_children_from_scope(parent, n), else: []
        mod = (parent && parent.meta[:module]) || find_enclosing_module(nodes, n.id)

        %{module: mod, location: Format.location(n), children: children}
      end)

    Enum.uniq_by(init_supervisors ++ inline_supervisors, & &1.module)
  end

  defp supervisor_init?(node) do
    node
    |> IR.all_nodes()
    |> Enum.any?(fn child ->
      child.type == :call and
        (child.meta[:function] in [:supervise, :init, :child_spec] or
           (child.meta[:module] == Supervisor and child.meta[:function] == :start_link))
    end)
  end

  defp extract_supervisor_children(func_node) do
    func_node
    |> IR.all_nodes()
    |> Enum.filter(&supervisor_start_link?/1)
    |> Enum.flat_map(&extract_children_from_scope(func_node, &1))
  end

  defp supervisor_start_link?(%{type: :call, meta: %{module: Supervisor, function: :start_link}}),
    do: true

  defp supervisor_start_link?(_), do: false

  defp extract_children_from_scope(func_node, call_node) do
    all = IR.all_nodes(func_node)

    case call_node.children do
      [first_arg | _] -> resolve_child_list(first_arg, all)
      _ -> []
    end
  end

  defp resolve_child_list(%{type: :list, children: items}, _all) do
    items |> Enum.map(&extract_child_module/1) |> Enum.reject(&is_nil/1)
  end

  defp resolve_child_list(%{type: :var, meta: %{name: var_name}}, all) do
    resolve_var_to_list(all, var_name)
  end

  defp resolve_child_list(_, _), do: []

  defp resolve_var_to_list(all_nodes, var_name) do
    case Enum.find(all_nodes, fn n ->
           n.type == :match and
             match?(
               [%{type: :var, meta: %{name: ^var_name, binding_role: :definition}} | _],
               n.children
             )
         end) do
      %{children: [_, %{type: :list, children: items}]} ->
        Enum.map(items, &extract_child_module/1)

      _ ->
        []
    end
  end

  defp extract_child_module(%{type: :literal, meta: %{value: mod}}) when is_atom(mod), do: mod
  defp extract_child_module(%{type: :struct, meta: %{name: mod}}), do: mod

  defp extract_child_module(%{type: :tuple, children: [first | _]}) do
    extract_child_module(first)
  end

  defp extract_child_module(%{type: :call, meta: %{function: :__aliases__}, children: parts}) do
    parts
    |> Enum.map(fn
      %{type: :literal, meta: %{value: v}} when is_atom(v) -> v
      _ -> nil
    end)
    |> then(fn atoms ->
      if Enum.all?(atoms, &is_atom/1), do: Module.concat(atoms)
    end)
  end

  defp extract_child_module(%{type: :call, meta: %{module: mod}})
       when is_atom(mod) and not is_nil(mod), do: mod

  defp extract_child_module(_), do: nil

  defp find_containing_function(nodes, target_id) do
    Enum.find(nodes, fn n ->
      n.type == :function_def and
        target_id in Enum.map(IR.all_nodes(n), & &1.id)
    end)
  end

  defp find_enclosing_module(nodes, target_id) do
    case Enum.find(nodes, fn n ->
           n.type == :module_def and
             target_id in Enum.map(IR.all_nodes(n), & &1.id)
         end) do
      %{meta: %{name: name}} -> name
      _ -> nil
    end
  end

  defp render_text(result, opts) do
    graph_mode = opts[:graph] || false

    if graph_mode and not BoxartGraph.available?() do
      Mix.raise("boxart is required for --graph. Add {:boxart, \"~> 0.3.3\"} to your deps.")
    end

    IO.puts(Format.header("OTP Analysis"))

    if result.behaviours == [] and result.state_machines == [] do
      IO.puts("No OTP behaviours detected.\n")
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
    IO.puts(Format.section("#{gs.module} #{Format.faint("(" <> gs.behaviour <> ")")}"))

    if graph_mode and BoxartGraph.available?() do
      BoxartGraph.render_otp_state_diagram(gs.state_transforms)
    end

    IO.puts("  Callbacks:")

    gs.state_transforms
    |> Enum.sort_by(fn t -> t.callback end)
    |> Enum.each(fn t ->
      {name, arity} = t.callback

      IO.puts(
        "    #{Format.bright("#{name}/#{arity}")}  #{action_label(t.action)}  #{t.location}"
      )
    end)
  end

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
    Enum.each(ops, fn op -> IO.puts("    #{op.action}  #{op.location}") end)
  end

  defp render_missing_handlers(handlers) do
    if handlers != [] do
      IO.puts(Format.section("Potentially unmatched messages"))

      Enum.each(handlers, fn h ->
        IO.puts("  #{h.location}  #{Format.warning("#{h.message} to unknown handler")}")
      end)
    end
  end

  defp render_dead_replies([]), do: :ok

  defp render_dead_replies(dead_replies) do
    IO.puts(Format.section("Dead GenServer replies"))

    Enum.each(dead_replies, fn dr ->
      target = if dr.target, do: " to #{inspect(dr.target)}", else: ""
      IO.puts("  #{dr.location}  #{Format.warning("GenServer.call#{target} reply discarded")}")
    end)
  end

  defp render_cross_process([]), do: :ok

  defp render_cross_process(findings) do
    IO.puts(Format.section("Cross-process coupling"))

    Enum.each(findings, fn f ->
      resource_label = format_resource(f.resource)
      IO.puts("  #{f.location}  #{inspect(f.caller)} → #{inspect(f.callee)}")
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
    IO.puts("  #{Format.bright(inspect(s.module))}  #{s.location}")
    Enum.each(s.children, fn child -> IO.puts("    └─ #{inspect(child)}") end)
  end

  defp action_label(:writes), do: Format.red("writes state")
  defp action_label(:read_write), do: Format.yellow("read+write")
  defp action_label(:reads), do: Format.green("reads state")
  defp action_label(:passes_through), do: Format.faint("passes through")
  defp action_label(:unknown), do: Format.faint("no state access")

  defp render_state_machine(sm) do
    mode_label = sm.callback_mode |> to_string() |> String.replace("_", " ")
    IO.puts(Format.section("#{sm.module} #{Format.faint("(gen_statem, #{mode_label})")}"))

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
