defmodule Reach.OTP.GenServer do
  @moduledoc false

  alias Reach.IR
  alias Reach.IR.Node

  @genserver_callbacks %{
    {:init, 1} => :init,
    {:handle_call, 3} => :handle_call,
    {:handle_cast, 2} => :handle_cast,
    {:handle_info, 2} => :handle_info,
    {:terminate, 2} => :terminate,
    {:code_change, 3} => :code_change
  }

  @doc """
  Classifies a function definition as a GenServer callback type.
  """
  @spec classify_callback(Node.t()) :: atom() | nil
  def classify_callback(%Node{type: :function_def, meta: %{name: name, arity: arity}}) do
    Map.get(@genserver_callbacks, {name, arity})
  end

  def classify_callback(_), do: nil

  @doc """
  Extracts the state parameter node from a GenServer callback.
  """
  @spec extract_state_param(Node.t()) :: Node.t() | nil
  def extract_state_param(%Node{type: :function_def} = func_def) do
    callback_type = classify_callback(func_def)

    case {callback_type, extract_params(func_def)} do
      {:init, [arg]} -> arg
      {:handle_call, [_msg, _from, state]} -> state
      {:handle_cast, [_msg, state]} -> state
      {:handle_info, [_msg, state]} -> state
      {:terminate, [_reason, state]} -> state
      _ -> nil
    end
  end

  @doc """
  Extracts the return value expression from a GenServer callback.
  """
  @spec extract_return_info(Node.t()) :: {atom(), Node.t() | nil, Node.t() | nil} | nil
  def extract_return_info(%Node{type: :function_def} = func_def) do
    all = IR.all_nodes(func_def)

    tuples =
      Enum.filter(all, fn node ->
        node.type == :tuple and tuple_is_genserver_return?(node)
      end)

    case tuples do
      [tuple | _] -> parse_genserver_return(tuple)
      [] -> nil
    end
  end

  @doc """
  Adds GenServer-specific edges (state flow, state pass, call reply) to a graph.
  """
  def add_edges(graph, all_nodes) do
    func_defs = Enum.filter(all_nodes, &(&1.type == :function_def))
    callbacks = Enum.filter(func_defs, &(classify_callback(&1) != nil))

    graph
    |> add_state_flow_edges(callbacks)
    |> add_state_pass_edges(callbacks)
    |> add_call_reply_edges(all_nodes)
  end

  # --- State flow ---

  defp add_state_flow_edges(graph, callbacks) do
    Enum.reduce(callbacks, graph, &add_state_reads_for_callback/2)
  end

  defp add_state_reads_for_callback(callback, graph) do
    state_param = extract_state_param(callback)
    state_name = if state_param, do: var_name(state_param)

    if state_name do
      graph = Graph.add_vertex(graph, state_param.id)

      callback
      |> IR.all_nodes()
      |> Enum.filter(&state_use?(&1, state_name, state_param.id))
      |> Enum.reduce(graph, fn use_node, g ->
        g
        |> Graph.add_vertex(use_node.id)
        |> Graph.add_edge(state_param.id, use_node.id, label: :state_read)
      end)
    else
      graph
    end
  end

  defp state_use?(%Node{type: :var, meta: %{name: name}, id: id}, state_name, param_id) do
    name == state_name and id != param_id
  end

  defp state_use?(_, _, _), do: false

  # --- State pass ---

  defp add_state_pass_edges(graph, callbacks) do
    callbacks
    |> Enum.filter(&(classify_callback(&1) in [:handle_call, :handle_cast, :handle_info]))
    |> Enum.sort_by(& &1.id)
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.reduce(graph, &connect_state_pass/2)
  end

  defp connect_state_pass([current, next], graph) do
    return_info = extract_return_info(current)
    next_state_param = extract_state_param(next)

    case {return_info, next_state_param} do
      {{_type, _reply, %Node{} = new_state}, %Node{} = next_param} ->
        graph
        |> Graph.add_vertex(new_state.id)
        |> Graph.add_vertex(next_param.id)
        |> Graph.add_edge(new_state.id, next_param.id, label: :state_pass)

      _ ->
        graph
    end
  end

  # --- Call reply ---

  defp add_call_reply_edges(graph, all_nodes) do
    call_sites =
      Enum.filter(all_nodes, fn node ->
        node.type == :call and
          node.meta[:module] == GenServer and
          node.meta[:function] == :call
      end)

    reply_nodes = find_reply_values(all_nodes)

    for call_site <- call_sites,
        {_tag, reply_value} <- reply_nodes,
        reduce: graph do
      g ->
        g
        |> Graph.add_vertex(reply_value.id)
        |> Graph.add_vertex(call_site.id)
        |> Graph.add_edge(reply_value.id, call_site.id, label: :call_reply)
    end
  end

  defp find_reply_values(all_nodes) do
    all_nodes
    |> Enum.filter(fn node ->
      node.type == :function_def and node.meta[:name] == :handle_call
    end)
    |> Enum.flat_map(fn func_def ->
      func_def
      |> IR.all_nodes()
      |> Enum.filter(fn node ->
        node.type == :tuple and
          match?([%{type: :literal, meta: %{value: :reply}} | _], node.children)
      end)
      |> Enum.flat_map(fn tuple ->
        case tuple.children do
          [_, reply_value | _] -> [{:reply, reply_value}]
          _ -> []
        end
      end)
    end)
  end

  # --- Helpers ---

  defp extract_params(%Node{
         type: :function_def,
         meta: %{arity: arity},
         children: [%Node{type: :clause, children: children} | _]
       }) do
    Enum.take(children, arity)
  end

  defp extract_params(_), do: []

  defp var_name(%Node{type: :var, meta: %{name: name}}), do: name
  defp var_name(_), do: nil

  defp tuple_is_genserver_return?(%Node{type: :tuple, children: children}) do
    case children do
      [%Node{type: :literal, meta: %{value: tag}} | _] when tag in [:reply, :noreply, :stop] ->
        true

      _ ->
        false
    end
  end

  defp parse_genserver_return(%Node{type: :tuple, children: children}) do
    case children do
      [%Node{meta: %{value: :reply}}, reply, new_state | _] ->
        {:reply, reply, new_state}

      [%Node{meta: %{value: :noreply}}, new_state | _] ->
        {:noreply, nil, new_state}

      [%Node{meta: %{value: :stop}}, _reason, new_state | _] ->
        {:stop, nil, new_state}

      [%Node{meta: %{value: :stop}}, _reason] ->
        {:stop, nil, nil}

      _ ->
        nil
    end
  end
end
