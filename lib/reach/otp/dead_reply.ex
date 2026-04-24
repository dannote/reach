defmodule Reach.OTP.DeadReply do
  @moduledoc false

  alias Reach.IR
  alias Reach.IR.Node

  @doc """
  Finds GenServer.call sites where the reply value is discarded.

  A discarded reply means the server computes and sends a value that
  nobody uses — the call could be a cast instead, or the handle_call
  could return a cheaper reply.
  """
  @spec find_dead_replies([Node.t()]) :: [map()]
  def find_dead_replies(nodes) do
    all_nodes = Enum.flat_map(nodes, &IR.all_nodes/1)
    parent_map = build_parent_map(all_nodes)

    all_nodes
    |> Enum.filter(fn n -> genserver_call?(n) and reply_discarded?(n, parent_map) end)
    |> Enum.map(fn call ->
      target = call_target(call)

      %{
        call_site: call,
        target: target,
        location: location(call)
      }
    end)
    |> Enum.uniq_by(& &1.location)
  end

  defp genserver_call?(%Node{type: :call, meta: %{module: GenServer, function: :call}}), do: true

  defp genserver_call?(%Node{type: :call, meta: %{module: :gen_server, function: :call}}),
    do: true

  defp genserver_call?(_), do: false

  defp reply_discarded?(call, parent_map) do
    parent = Map.get(parent_map, call.id)
    if parent == nil, do: true, else: value_unused?(call, parent)
  end

  defp value_unused?(call, parent) do
    case parent.type do
      :block ->
        last = List.last(parent.children)
        last == nil or last.id != call.id

      :function_def ->
        false

      _ ->
        false
    end
  end

  defp call_target(%Node{children: [target | _]}) do
    case target do
      %Node{type: :literal, meta: %{value: mod}} when is_atom(mod) ->
        mod

      %Node{type: :var, meta: %{name: name}} ->
        name

      %Node{type: :call, meta: %{function: :__aliases__}, children: parts} ->
        atoms =
          Enum.map(parts, fn
            %{type: :literal, meta: %{value: v}} when is_atom(v) -> v
            _ -> nil
          end)

        if Enum.all?(atoms, & &1), do: Module.concat(atoms)

      _ ->
        nil
    end
  end

  defp call_target(_), do: nil

  defp build_parent_map(all_nodes) do
    for node <- all_nodes,
        child <- node.children || [],
        into: %{} do
      {child.id, node}
    end
  end

  defp location(%{source_span: %{file: file, start_line: line}}) do
    "#{file}:#{line}"
  end

  defp location(%{source_span: %{start_line: line}}) do
    "line #{line}"
  end

  defp location(_), do: "unknown"
end
