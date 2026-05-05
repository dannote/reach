defmodule Reach.OTP.DeadReply do
  @moduledoc "Detects GenServer.call sites where the reply value is discarded."

  alias Reach.Analysis
  alias Reach.IR
  alias Reach.IR.Node

  @doc """
  Finds GenServer.call sites where the reply value is discarded.

  A discarded reply means the server computes and sends a value that
  nobody uses — the call could be a cast instead, or the handle_call
  could return a cheaper reply.
  """
  @spec find_dead_replies([Node.t()], keyword()) :: [map()]
  def find_dead_replies(nodes, opts \\ []) do
    all_nodes =
      Keyword.get_lazy(opts, :all_nodes, fn -> Enum.flat_map(nodes, &IR.all_nodes/1) end)

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
        last = parent.children |> Enum.reverse() |> List.first()
        last == nil or last.id != call.id

      :function_def ->
        false

      _ ->
        false
    end
  end

  defp call_target(node), do: Analysis.call_target(node)

  defp build_parent_map(all_nodes) do
    for node <- all_nodes,
        child <- node.children || [],
        into: %{} do
      {child.id, node}
    end
  end

  defp location(node), do: Analysis.location(node)
end
