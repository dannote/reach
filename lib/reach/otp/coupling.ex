defmodule Reach.OTP.Coupling do
  @moduledoc false

  alias Reach.IR.Node

  @doc """
  Adds hidden coupling edges (ETS, process dict, message ordering/content) to a graph.
  """
  def add_edges(graph, all_nodes) do
    graph
    |> add_ets_edges(all_nodes)
    |> add_process_dict_edges(all_nodes)
    |> add_message_order_edges(all_nodes)
    |> add_message_content_edges(all_nodes)
  end

  # --- ETS edges ---

  defp add_ets_edges(graph, all_nodes) do
    ets_calls = Enum.filter(all_nodes, &ets_call?/1)
    writes = Enum.filter(ets_calls, &ets_write?/1)
    reads = Enum.filter(ets_calls, &ets_read?/1)

    for write <- writes,
        read <- reads,
        write.id != read.id,
        same_ets_table?(write, read),
        reduce: graph do
      g ->
        g
        |> Graph.add_vertex(write.id)
        |> Graph.add_vertex(read.id)
        |> Graph.add_edge(write.id, read.id, label: {:ets_dep, ets_table_name(write)})
    end
  end

  defp ets_call?(%Node{type: :call, meta: %{module: :ets}}), do: true
  defp ets_call?(_), do: false

  @ets_write_ops [:insert, :insert_new, :delete, :delete_object, :update_counter, :update_element]
  @ets_read_ops [:lookup, :lookup_element, :match, :match_object, :select, :member, :info]

  defp ets_write?(%Node{type: :call, meta: %{module: :ets, function: f}})
       when f in @ets_write_ops,
       do: true

  defp ets_write?(_), do: false

  defp ets_read?(%Node{type: :call, meta: %{module: :ets, function: f}})
       when f in @ets_read_ops,
       do: true

  defp ets_read?(_), do: false

  defp same_ets_table?(a, b) do
    table_a = ets_table_name(a)
    table_b = ets_table_name(b)
    table_a != nil and table_a == table_b
  end

  defp ets_table_name(%Node{children: [%Node{type: :literal, meta: %{value: name}} | _]})
       when is_atom(name),
       do: name

  defp ets_table_name(%Node{children: [%Node{type: :var, meta: %{name: name}} | _]}),
    do: name

  defp ets_table_name(_), do: nil

  # --- Process dictionary edges ---

  defp add_process_dict_edges(graph, all_nodes) do
    writes = Enum.filter(all_nodes, &pdict_write?/1)
    reads = Enum.filter(all_nodes, &pdict_read?/1)

    for write <- writes,
        read <- reads,
        write.id != read.id,
        same_pdict_key?(write, read),
        reduce: graph do
      g ->
        g
        |> Graph.add_vertex(write.id)
        |> Graph.add_vertex(read.id)
        |> Graph.add_edge(write.id, read.id, label: {:pdict_dep, pdict_key(write)})
    end
  end

  defp pdict_write?(%Node{type: :call, meta: %{module: Process, function: :put}}), do: true
  defp pdict_write?(%Node{type: :call, meta: %{module: Process, function: :delete}}), do: true
  defp pdict_write?(_), do: false

  defp pdict_read?(%Node{type: :call, meta: %{module: Process, function: :get}}), do: true
  defp pdict_read?(%Node{type: :call, meta: %{module: Process, function: :get_keys}}), do: true
  defp pdict_read?(_), do: false

  defp same_pdict_key?(write, read) do
    key_w = pdict_key(write)
    key_r = pdict_key(read)
    key_w == nil or key_r == nil or key_w == key_r
  end

  defp pdict_key(%Node{children: [%Node{type: :literal, meta: %{value: key}} | _]}), do: key
  defp pdict_key(_), do: nil

  # --- Message ordering ---

  defp add_message_order_edges(graph, all_nodes) do
    sends =
      all_nodes
      |> Enum.filter(&send_call?/1)
      |> Enum.sort_by(& &1.id)

    sends
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.reduce(graph, fn [a, b], g ->
      if same_send_target?(a, b) do
        g
        |> Graph.add_vertex(a.id)
        |> Graph.add_vertex(b.id)
        |> Graph.add_edge(a.id, b.id, label: :message_order)
      else
        g
      end
    end)
  end

  defp send_call?(%Node{type: :call, meta: %{function: :send, kind: :local}}), do: true
  defp send_call?(%Node{type: :call, meta: %{module: Process, function: :send}}), do: true

  defp send_call?(%Node{type: :call, meta: %{module: GenServer, function: f}})
       when f in [:call, :cast],
       do: true

  defp send_call?(_), do: false

  defp same_send_target?(a, b) do
    target_a = send_target(a)
    target_b = send_target(b)
    target_a != nil and target_a == target_b
  end

  defp send_target(%Node{children: [%Node{type: :var, meta: %{name: name}} | _]}), do: name
  defp send_target(%Node{children: [%Node{type: :literal, meta: %{value: val}} | _]}), do: val
  defp send_target(_), do: nil

  # --- Message content flow ---

  defp add_message_content_edges(graph, all_nodes) do
    sends = Enum.filter(all_nodes, &send_with_payload?/1)
    handlers = find_message_handlers(all_nodes)

    for send_node <- sends,
        {handler_def, pattern_vars} <- handlers,
        {tag, payload_nodes} = extract_send_payload(send_node),
        tag != nil,
        {handler_tag, handler_vars} <- [{extract_handler_tag(handler_def), pattern_vars}],
        tag == handler_tag,
        payload <- payload_nodes,
        var <- handler_vars,
        reduce: graph do
      g ->
        g
        |> Graph.add_vertex(payload.id)
        |> Graph.add_vertex(var.id)
        |> Graph.add_edge(payload.id, var.id, label: {:message_content, tag})
    end
  end

  defp send_with_payload?(%Node{
         type: :call,
         meta: %{function: :send, kind: :local},
         children: [_, _]
       }),
       do: true

  defp send_with_payload?(%Node{
         type: :call,
         meta: %{module: Process, function: :send},
         children: [_, _]
       }),
       do: true

  defp send_with_payload?(%Node{
         type: :call,
         meta: %{module: GenServer, function: f},
         children: [_, _ | _]
       })
       when f in [:call, :cast],
       do: true

  defp send_with_payload?(_), do: false

  defp extract_send_payload(%Node{children: [_target, payload | _]}) do
    case payload do
      %Node{type: :tuple, children: [%Node{type: :literal, meta: %{value: tag}} | rest]}
      when is_atom(tag) ->
        {tag, rest}

      %Node{type: :literal, meta: %{value: tag}} when is_atom(tag) ->
        {tag, []}

      _ ->
        {nil, []}
    end
  end

  defp find_message_handlers(all_nodes) do
    all_nodes
    |> Enum.filter(fn node ->
      node.type == :function_def and
        node.meta[:name] in [:handle_info, :handle_cast, :handle_call]
    end)
    |> Enum.flat_map(fn func_def ->
      func_def.children
      |> Enum.filter(&(&1.type == :clause))
      |> Enum.map(fn clause ->
        pattern_vars =
          clause.children
          |> Enum.take_while(&(&1.type != :guard))
          |> Enum.flat_map(&collect_pattern_vars/1)

        {clause, pattern_vars}
      end)
    end)
  end

  defp extract_handler_tag(%Node{type: :clause, children: [first | _]}) do
    case first do
      %Node{type: :tuple, children: [%Node{type: :literal, meta: %{value: tag}} | _]}
      when is_atom(tag) ->
        tag

      %Node{type: :literal, meta: %{value: tag}} when is_atom(tag) ->
        tag

      _ ->
        nil
    end
  end

  defp collect_pattern_vars(%Node{type: :var, meta: %{binding_role: :definition}} = node) do
    [node]
  end

  defp collect_pattern_vars(%Node{children: children}) do
    Enum.flat_map(children, &collect_pattern_vars/1)
  end

  defp collect_pattern_vars(_), do: []
end
