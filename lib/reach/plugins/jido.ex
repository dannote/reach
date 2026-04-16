defmodule Reach.Plugins.Jido do
  @moduledoc false
  @behaviour Reach.Plugin

  alias Reach.IR

  import Reach.Plugins.Helpers, only: [find_vars_in: 1]

  @impl true
  def analyze(all_nodes, _opts) do
    action_run_edges(all_nodes) ++
      cmd_directive_edges(all_nodes) ++
      signal_dispatch_edges(all_nodes) ++
      tool_execute_edges(all_nodes) ++
      memory_edges(all_nodes)
  end

  @impl true
  def analyze_project(_modules, all_nodes, _opts) do
    action_to_cmd_edges(all_nodes) ++
      signal_cross_module_edges(all_nodes)
  end

  # Action: params in run/2 → calls in run body (taint source from external input)
  defp action_run_edges(all_nodes) do
    run_fns = find_function_defs(all_nodes, :run, 2)

    Enum.flat_map(run_fns, fn func ->
      param_defs = first_param_defs(func)
      func_nodes = IR.all_nodes(func)

      calls =
        Enum.filter(func_nodes, fn n ->
          n.type == :call and n.meta[:binding_role] != :definition
        end)

      for param <- param_defs,
          call <- calls do
        {param.id, call.id, {:jido_action_params, func.meta[:module]}}
      end
    end)
  end

  # cmd/2,3: action tuple args → directive structs in return
  defp cmd_directive_edges(all_nodes) do
    cmd_fns = find_function_defs(all_nodes, :cmd, nil)

    Enum.flat_map(cmd_fns, fn func ->
      func_nodes = IR.all_nodes(func)

      structs =
        Enum.filter(func_nodes, fn n ->
          n.type == :struct and directive_struct?(n.meta[:name])
        end)

      params = first_param_defs(func)

      for param <- params, struct_node <- structs do
        {param.id, struct_node.id, {:jido_directive, struct_node.meta[:name]}}
      end
    end)
  end

  # Signal.Dispatch: dispatch calls with signal data
  defp signal_dispatch_edges(all_nodes) do
    dispatch_calls =
      Enum.filter(all_nodes, fn n ->
        n.type == :call and
          dispatch_module?(n.meta[:module]) and
          n.meta[:function] in [:dispatch, :dispatch_async, :dispatch_batch]
      end)

    for call <- dispatch_calls,
        arg <- call.children,
        var <- find_vars_in(arg) do
      {var.id, call.id, :jido_signal_dispatch}
    end
  end

  # Turn.execute: tool_name + params flow into tool execution (prompt injection path)
  defp tool_execute_edges(all_nodes) do
    execute_calls =
      Enum.filter(all_nodes, fn n ->
        n.type == :call and
          n.meta[:function] in [:execute, :execute_module] and
          n.meta[:module] in [nil, Jido.AI.Turn]
      end)

    for call <- execute_calls,
        arg <- call.children,
        var <- find_vars_in(arg) do
      {var.id, call.id, :jido_tool_execute}
    end
  end

  # Memory: remember/recall as state write/read
  defp memory_edges(all_nodes) do
    func_defs = Enum.filter(all_nodes, &(&1.type == :function_def))

    remembers =
      Enum.filter(all_nodes, &(&1.type == :call and &1.meta[:function] == :remember))

    write_edges =
      for call <- remembers, arg <- call.children, var <- find_vars_in(arg) do
        {var.id, call.id, :jido_memory_write}
      end

    recalls =
      Enum.filter(all_nodes, &(&1.type == :call and &1.meta[:function] == :recall))

    read_edges =
      for call <- recalls,
          func <- func_defs,
          func |> IR.all_nodes() |> Enum.any?(&(&1.id == call.id)) do
        {call.id, func.id, :jido_memory_read}
      end

    write_edges ++ read_edges
  end

  # Cross-module: Exec.run(ActionModule, params) → ActionModule.run/2
  defp action_to_cmd_edges(all_nodes) do
    exec_calls =
      Enum.filter(all_nodes, fn n ->
        n.type == :call and
          n.meta[:module] in [Jido.Exec, nil] and
          n.meta[:function] == :run
      end)

    run_fns = find_function_defs(all_nodes, :run, 2)

    runs_by_module =
      Map.new(run_fns, fn f -> {f.meta[:module], f} end)

    Enum.flat_map(exec_calls, &exec_to_run_edges(&1, runs_by_module))
  end

  defp exec_to_run_edges(call, runs_by_module) do
    with mod when mod != nil <- extract_action_module(call),
         %{} = run_fn <- Map.get(runs_by_module, mod) do
      [{call.id, run_fn.id, {:jido_exec, mod}}]
    else
      _ -> []
    end
  end

  # Cross-module: Dispatch in module A → handler in module B
  defp signal_cross_module_edges(all_nodes) do
    dispatches =
      Enum.filter(all_nodes, fn n ->
        n.type == :call and
          dispatch_module?(n.meta[:module]) and
          n.meta[:function] in [:dispatch, :dispatch_async]
      end)

    handlers =
      Enum.filter(all_nodes, fn n ->
        n.type == :function_def and
          n.meta[:name] in [:handle_signal, :handle_info, :handle_event]
      end)

    for dispatch <- dispatches,
        handler <- handlers do
      {dispatch.id, handler.id, :jido_signal_route}
    end
  end

  defp find_function_defs(all_nodes, name, arity) do
    Enum.filter(all_nodes, fn n ->
      n.type == :function_def and n.meta[:name] == name and
        (arity == nil or n.meta[:arity] == arity)
    end)
  end

  defp first_param_defs(func) do
    func.children
    |> Enum.filter(&(&1.type == :clause))
    |> Enum.flat_map(fn clause ->
      clause.children
      |> Enum.filter(fn n ->
        n.type == :var and n.meta[:binding_role] == :definition
      end)
      |> Enum.take(1)
    end)
  end

  defp directive_struct?(name) when is_atom(name) do
    name_str = Atom.to_string(name)

    String.contains?(name_str, "Directive") or
      name in [
        Jido.Agent.Directive.Emit,
        Jido.Agent.Directive.Spawn,
        Jido.Agent.Directive.Schedule,
        Jido.Agent.Directive.Stop,
        Jido.Agent.Directive.Error,
        Jido.Agent.Directive.RunInstruction
      ]
  end

  defp directive_struct?(_), do: false

  @dispatch_modules [
    Jido.Signal.Dispatch,
    Jido.Signal.Dispatch.Bus,
    Jido.Signal.Dispatch.PubSub,
    Jido.Signal.Dispatch.Named
  ]

  defp dispatch_module?(mod) when is_atom(mod), do: mod in @dispatch_modules
  defp dispatch_module?(_), do: false

  defp extract_action_module(call) do
    call.children
    |> Enum.find_value(fn n ->
      if n.type == :literal and is_atom(n.meta[:value]) and n.meta[:value] != nil do
        n.meta[:value]
      end
    end)
  end
end
