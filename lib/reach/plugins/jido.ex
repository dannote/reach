defmodule Reach.Plugins.Jido do
  @moduledoc false
  @behaviour Reach.Plugin

  alias Reach.IR
  alias Reach.IR.Node

  import Reach.Plugins.Helpers, only: [find_vars_in: 1]

  # jido_signal package
  @dispatch_modules [
    Jido.Signal.Dispatch,
    Jido.Signal.Dispatch.Bus,
    Jido.Signal.Dispatch.PubSub,
    Jido.Signal.Dispatch.Named,
    Jido.Signal.Dispatch.Pid,
    Jido.Signal.Dispatch.Logger,
    Jido.Signal.Dispatch.Console,
    Jido.Signal.Dispatch.Webhook
  ]

  @impl true
  def classify_effect(%Node{type: :call, meta: %{module: mod, function: fun}})
      when mod in @dispatch_modules and
             fun in [:dispatch, :dispatch_async, :dispatch_batch],
      do: :send

  # Agent directives that cause side effects
  def classify_effect(%Node{type: :call, meta: %{module: Jido.Agent.Directive, function: fun}})
      when fun in [:emit],
      do: :send

  def classify_effect(%Node{type: :call, meta: %{module: Jido.Agent.Directive, function: fun}})
      when fun in [:spawn, :spawn_agent, :adopt_child, :stop_child, :schedule,
                   :cron, :cancel_cron],
      do: :io

  def classify_effect(%Node{type: :call, meta: %{module: Jido.Agent.Directive, function: fun}})
      when fun in [:error],
      do: :exception

  # Signal construction is pure
  def classify_effect(%Node{type: :call, meta: %{module: Signal, function: fun}})
      when fun in [:new, :new!, :from_map, :serialize, :deserialize],
      do: :pure

  # AgentServer — message passing
  def classify_effect(%Node{type: :call, meta: %{module: Jido.AgentServer, function: fun}})
      when fun in [:call, :cast],
      do: :send

  def classify_effect(%Node{type: :call, meta: %{module: Jido.AgentServer, function: fun}})
      when fun in [:start, :start_link, :stop_child, :adopt_child, :adopt_parent],
      do: :io

  def classify_effect(%Node{type: :call, meta: %{module: Jido.AgentServer, function: fun}})
      when fun in [:state, :status, :alive?, :whereis, :via_tuple],
      do: :read

  # Agent struct operations — pure
  def classify_effect(%Node{type: :call, meta: %{module: Jido.Agent, function: fun}})
      when fun in [:new, :set, :validate, :schema, :config_schema],
      do: :pure

  # Persist — storage IO
  def classify_effect(%Node{type: :call, meta: %{module: Jido.Persist, function: fun}})
      when fun in [:hibernate, :thaw, :persist_scheduler_manifest],
      do: :write

  # Memory — state access
  def classify_effect(%Node{type: :call, meta: %{function: :remember}}), do: :write
  def classify_effect(%Node{type: :call, meta: %{function: :recall}}), do: :read

  # Thread — pure data structure
  def classify_effect(%Node{type: :call, meta: %{module: Jido.Thread, function: fun}})
      when fun in [:new, :append, :entry_count, :last, :get_entry, :to_list,
                   :filter_by_kind, :slice],
      do: :pure

  # Signal journal — storage
  def classify_effect(%Node{type: :call, meta: %{module: mod, function: fun}})
      when is_atom(mod) and mod != nil and fun in [:persist, :read, :query] do
    mod_str = Atom.to_string(mod)
    if String.contains?(mod_str, "Journal"), do: :write
  end

  def classify_effect(_), do: nil

  @impl true
  def analyze(all_nodes, _opts) do
    action_run_edges(all_nodes) ++
      signal_dispatch_edges(all_nodes) ++
      tool_execute_edges(all_nodes) ++
      memory_edges(all_nodes)
  end

  @impl true
  def analyze_project(_modules, all_nodes, _opts) do
    signal_cross_module_edges(all_nodes)
  end

  defp action_run_edges(all_nodes) do
    run_fns = find_function_defs(all_nodes, :run, 2)

    Enum.flat_map(run_fns, fn func ->
      param_defs = first_param_defs(func)
      func_nodes = IR.all_nodes(func)

      calls =
        Enum.filter(func_nodes, fn n ->
          n.type == :call and n.meta[:binding_role] != :definition
        end)

      for param <- param_defs, call <- calls do
        {param.id, call.id, {:jido_action_params, func.meta[:module]}}
      end
    end)
  end

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

    for dispatch <- dispatches, handler <- handlers do
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

  defp dispatch_module?(mod) when is_atom(mod), do: mod in @dispatch_modules
  defp dispatch_module?(_), do: false
end
