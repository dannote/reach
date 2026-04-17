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

  @switches [format: :string]
  @aliases [f: :format]

  @impl Mix.Task
  def run(args) do
    {opts, target_args, _} = OptionParser.parse(args, switches: @switches, aliases: @aliases)
    format = opts[:format] || "text"

    project = Reach.CLI.Project.load()
    scope = if target_args != [], do: hd(target_args), else: nil

    result = analyze(project, scope)

    case format do
      "json" -> Reach.CLI.Format.render(result, "reach.otp", format: "json", pretty: true)
      "oneline" -> render_oneline(result)
      _ -> render_text(result)
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
    |> Enum.group_by(fn n ->
      mod = n.meta[:module]
      file = if n.source_span, do: n.source_span[:file], else: nil
      key = mod || file
      if scope && key && to_string(key) =~ scope, do: key, else: (if scope, do: nil, else: key)
    end)
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

  defp group_callbacks(func_defs) do
    func_defs
    |> Enum.filter(fn n ->
      n.meta[:name] in [
        :init, :handle_call, :handle_cast, :handle_info,
        :handle_continue, :terminate, :code_change
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
      all = Reach.IR.all_nodes(node)

      _state_param = find_state_param(node, arity)
      writes = count_state_writes(all)
      reads = count_state_reads(all)

      action =
        cond do
          writes > 0 and reads == 0 -> :writes
          writes > 0 and reads > 0 -> :read_write
          reads > 0 -> :reads
          true -> :unknown
        end

      %{
        callback: {name, arity},
        action: action,
        location: Reach.CLI.Format.location(node)
      }
    end)
  end

  defp find_state_param(node, arity) do
    node.children
    |> Enum.filter(&(&1.type == :clause))
    |> Enum.flat_map(fn clause ->
      clause.children |> Enum.take(arity) |> Enum.take(-1)
    end)
    |> Enum.filter(&(&1.type == :var))
    |> List.first()
  end

  defp count_state_writes(nodes) do
    Enum.count(nodes, fn n ->
      n.type == :call and n.meta[:function] in [:put, :update, :update!] and
        n.meta[:module] in [Map, Keyword, Process]
    end)
  end

  defp count_state_reads(nodes) do
    Enum.count(nodes, fn n ->
      n.type == :call and n.meta[:function] in [:get, :fetch, :fetch!] and
        n.meta[:module] in [Map, Keyword, Process]
    end)
  end

  defp find_hidden_coupling(nodes) do
    ets_ops =
      nodes
      |> Enum.filter(fn n ->
        n.type == :call and n.meta[:module] == :ets
      end)
      |> Enum.map(fn n ->
        func = n.meta[:function]
        action =
          case func do
            f when f in [:insert, :insert_new, :delete] -> :write
            f when f in [:lookup, :lookup_element, :match, :select, :member] -> :read
            _ -> :unknown
          end
        %{action: action, function: func, node: n, location: Reach.CLI.Format.location(n)}
      end)
      |> Enum.group_by(fn op ->
        # Try to extract table name from first child (literal)
        case op.node.children do
          [%{type: :literal, meta: %{value: name}} | _] when is_atom(name) -> name
          _ -> :unknown_table
        end
      end)

    pdict_ops =
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
          location: Reach.CLI.Format.location(n)
        }
      end)
      |> Enum.group_by(& &1.key)

    %{ets: ets_ops, process_dict: pdict_ops}
  end

  defp find_missing_handlers(nodes) do
    sends =
      nodes
      |> Enum.filter(fn n ->
        n.type == :call and n.meta[:function] in [:cast, :call] and
          n.meta[:module] == GenServer
      end)

    handles =
      nodes
      |> Enum.filter(fn n ->
        n.type == :function_def and n.meta[:name] in [:handle_call, :handle_cast, :handle_info]
      end)
      |> Enum.flat_map(fn func ->
        func.children
        |> Enum.filter(&(&1.type == :clause))
        |> Enum.flat_map(fn clause ->
          clause.children
          |> Enum.take(func.meta[:arity])
          |> Enum.filter(&(&1.type == :tuple))
          |> Enum.map(fn tuple_node ->
            tuple_node.children
            |> Enum.filter(&(&1.type == :literal))
            |> Enum.map(& &1.meta[:value])
          end)
        end)
      end)
      |> MapSet.new()

    sends
    |> Enum.filter(fn send_node ->
      case send_node.children do
        [_mod_or_pid, %{type: :literal, meta: %{value: msg_type}} | _] ->
          msg_type not in handles

        [%{type: :literal, meta: %{value: msg_type}} | _] ->
          msg_type not in handles

        _ ->
          false
      end
    end)
    |> Enum.map(fn n ->
      %{location: Reach.CLI.Format.location(n), message: n.meta[:function]}
    end)
  end

  defp find_supervision(nodes) do
    nodes
    |> Enum.filter(fn n ->
      n.type == :function_def and n.meta[:name] == :init and n.meta[:arity] == 1
    end)
    |> Enum.filter(fn n ->
      all = Reach.IR.all_nodes(n)
      Enum.any?(all, fn child ->
        child.type == :call and child.meta[:function] in [:supervise, :init, :child_spec]
      end)
    end)
    |> Enum.map(fn n ->
      %{
        module: n.meta[:module],
        location: Reach.CLI.Format.location(n)
      }
    end)
  end

  defp render_text(result) do
    IO.puts(Reach.CLI.Format.header("OTP Analysis"))

    if result.behaviours == [] do
      IO.puts("No OTP behaviours detected.\n")
    else
      Enum.each(result.behaviours, fn gs ->
        IO.puts(Reach.CLI.Format.section("#{gs.module} (#{gs.behaviour})"))

        IO.puts("  Callbacks:")

        gs.state_transforms
        |> Enum.sort_by(fn t -> t.callback end)
        |> Enum.each(fn t ->
          {name, arity} = t.callback
          action_str = action_label(t.action)
          IO.puts("    #{name}/#{arity}  #{action_str}  #{t.location}")
        end)
      end)
    end

    coupling = result.hidden_coupling

    ets_tables = coupling.ets |> Enum.reject(fn {k, _} -> k == :unknown_table end)
    if ets_tables != [] do
      IO.puts(Reach.CLI.Format.section("Hidden coupling (ETS)"))
      Enum.each(ets_tables, fn {table, ops} ->
        IO.puts("  :#{table}")
        Enum.each(ops, fn op ->
          IO.puts("    #{op.action}  #{op.location}")
        end)
      end)
    end

    pdict_keys = coupling.process_dict |> Enum.reject(fn {k, _} -> k == :unknown_key end)
    if pdict_keys != [] do
      IO.puts(Reach.CLI.Format.section("Process dictionary"))
      Enum.each(pdict_keys, fn {key, ops} ->
        IO.puts("  :#{key}")
        Enum.each(ops, fn op ->
          IO.puts("    #{op.action}  #{op.location}")
        end)
      end)
    end

    if result.missing_handlers != [] do
      IO.puts(Reach.CLI.Format.section("Potentially unmatched messages"))
      Enum.each(result.missing_handlers, fn h ->
        IO.puts("  #{h.location}  #{h.message} to unknown handler ⚠")
      end)
    end

    if result.supervision != [] do
      IO.puts(Reach.CLI.Format.section("Supervisors"))
      Enum.each(result.supervision, fn s ->
        IO.puts("  #{s.module}  #{s.location}")
      end)
    end
  end

  defp action_label(:writes), do: "writes state"
  defp action_label(:read_write), do: "read+write"
  defp action_label(:reads), do: "reads state"
  defp action_label(:unknown), do: "no state access"

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
