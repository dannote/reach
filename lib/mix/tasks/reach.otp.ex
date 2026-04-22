defmodule Mix.Tasks.Reach.Otp do
  @moduledoc """
  Shows GenServer state machines, missing message handlers, and hidden coupling.

      mix reach.otp
      mix reach.otp UserWorker
      mix reach.otp --format json

  ## Options

    * `--format` — output format: `text` (default), `json`, `oneline`

  """

  use Mix.Task

  @shortdoc "Show OTP state machine analysis"

  @switches [format: :string, graph: :boolean]
  @aliases [f: :format]

  alias Reach.CLI.BoxartGraph
  alias Reach.CLI.Format
  alias Reach.CLI.Project
  alias Reach.IR

  @impl Mix.Task
  def run(args) do
    {opts, target_args, _} = OptionParser.parse(args, switches: @switches, aliases: @aliases)
    format = opts[:format] || "text"

    project = Project.load()
    scope = if target_args != [], do: hd(target_args), else: nil

    result = analyze(project, scope)

    case format do
      "json" -> Format.render(result, "reach.otp", format: "json", pretty: true)
      "oneline" -> render_oneline(result)
      _ -> render_text(result, opts)
    end
  end

  defp analyze(project, scope) do
    nodes = Map.values(project.nodes)

    behaviours = find_gen_servers(nodes, scope)
    hidden_coupling = find_hidden_coupling(nodes)
    missing_handlers = find_missing_handlers(nodes)
    supervision = find_supervision(nodes)

    %{
      behaviours: behaviours,
      hidden_coupling: hidden_coupling,
      missing_handlers: missing_handlers,
      supervision: supervision
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
    nodes
    |> Enum.filter(fn n ->
      n.type == :function_def and n.meta[:name] == :init and n.meta[:arity] == 1 and
        supervisor_init?(n)
    end)
    |> Enum.map(fn n ->
      %{
        module: n.meta[:module],
        location: Format.location(n)
      }
    end)
  end

  defp supervisor_init?(node) do
    node
    |> IR.all_nodes()
    |> Enum.any?(fn child ->
      child.type == :call and child.meta[:function] in [:supervise, :init, :child_spec]
    end)
  end

  defp render_text(result, opts) do
    IO.puts(Format.header("OTP Analysis"))

    if result.behaviours == [] do
      IO.puts("No OTP behaviours detected.\n")
    else
      graph_mode = opts[:graph] || false
      Enum.each(result.behaviours, &render_behaviour(&1, graph_mode))
    end

    render_ets_coupling(result.hidden_coupling.ets)
    render_pdict_coupling(result.hidden_coupling.process_dict)
    render_missing_handlers(result.missing_handlers)
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

  defp render_supervision(supervision) do
    if supervision != [] do
      IO.puts(Format.section("Supervisors"))

      Enum.each(supervision, fn s ->
        IO.puts("  #{s.module}  #{s.location}")
      end)
    end
  end

  defp action_label(:writes), do: Format.red("writes state")
  defp action_label(:read_write), do: Format.yellow("read+write")
  defp action_label(:reads), do: Format.green("reads state")
  defp action_label(:passes_through), do: Format.faint("passes through")
  defp action_label(:unknown), do: Format.faint("no state access")

  defp render_oneline(result) do
    Enum.each(result.behaviours, fn gs ->
      Enum.each(gs.state_transforms, fn t ->
        {name, arity} = t.callback
        IO.puts("#{gs.module} #{name}/#{arity} #{t.action} #{t.location}")
      end)
    end)

    Enum.each(result.missing_handlers, fn h ->
      IO.puts("unmatched:#{h.location}:#{h.message}")
    end)
  end
end
