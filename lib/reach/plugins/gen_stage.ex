defmodule Reach.Plugins.GenStage do
  @moduledoc false
  @behaviour Reach.Plugin

  alias Reach.IR.Node

  @impl true
  def classify_effect(%Node{type: :call, meta: %{module: GenStage, function: fun}})
      when fun in [:call, :cast],
      do: :send

  def classify_effect(%Node{type: :call, meta: %{module: GenStage, function: fun}})
      when fun in [:start_link, :stop, :async_info],
      do: :io

  def classify_effect(%Node{type: :call, meta: %{module: GenStage, function: fun}})
      when fun in [:demand, :estimate_buffered_count],
      do: :read

  # Broadway
  def classify_effect(%Node{type: :call, meta: %{module: Broadway, function: fun}})
      when fun in [:start_link, :stop, :push_messages],
      do: :io

  def classify_effect(%Node{type: :call, meta: %{module: Broadway, function: fun}})
      when fun in [:producer_names, :topology, :all_running, :get_rate_limiting],
      do: :read

  def classify_effect(%Node{type: :call, meta: %{module: Broadway, function: fun}})
      when fun in [:test_message, :test_batch, :update_rate_limiting],
      do: :write

  # Broadway.Message — pure struct transforms
  def classify_effect(%Node{type: :call, meta: %{module: Broadway.Message, function: fun}})
      when fun in [
             :update_data,
             :put_data,
             :put_batcher,
             :put_batch_key,
             :put_batch_mode,
             :configure_ack,
             :failed,
             :ack_immediately
           ],
      do: :pure

  def classify_effect(_), do: nil

  @impl true
  def analyze(all_nodes, _opts) do
    demand_to_events_edges(all_nodes) ++
      broadway_message_edges(all_nodes)
  end

  defp demand_to_events_edges(all_nodes) do
    demand_fns =
      Enum.filter(all_nodes, fn n ->
        n.type == :function_def and n.meta[:name] == :handle_demand
      end)

    events_fns =
      Enum.filter(all_nodes, fn n ->
        n.type == :function_def and n.meta[:name] == :handle_events
      end)

    for demand <- demand_fns,
        events <- events_fns,
        return_node <- return_nodes(demand),
        param_node <- first_param_nodes(events) do
      {return_node.id, param_node.id, :gen_stage_pipeline}
    end
  end

  defp broadway_message_edges(all_nodes) do
    msg_fns =
      Enum.filter(all_nodes, fn n ->
        n.type == :function_def and n.meta[:name] == :handle_message
      end)

    batch_fns =
      Enum.filter(all_nodes, fn n ->
        n.type == :function_def and n.meta[:name] == :handle_batch
      end)

    for msg <- msg_fns,
        batch <- batch_fns,
        return_node <- return_nodes(msg),
        param_node <- nth_param_nodes(batch, 1) do
      {return_node.id, param_node.id, :broadway_pipeline}
    end
  end

  defp return_nodes(func_def) do
    func_def.children
    |> Enum.filter(&(&1.type == :clause))
    |> Enum.map(&last_expression/1)
    |> Enum.reject(&is_nil/1)
  end

  defp first_param_nodes(func_def), do: nth_param_nodes(func_def, 0)

  defp nth_param_nodes(func_def, n) do
    func_def.children
    |> Enum.filter(&(&1.type == :clause))
    |> Enum.flat_map(fn clause ->
      params =
        clause.children
        |> Enum.filter(fn c -> c.meta[:binding_role] == :definition or c.type != :var end)

      case Enum.at(params, n) do
        nil -> []
        param -> [param]
      end
    end)
  end

  defp last_expression(clause) do
    clause.children
    |> Enum.filter(fn c ->
      c.type != :var or c.meta[:binding_role] != :definition
    end)
    |> List.last()
  end
end
