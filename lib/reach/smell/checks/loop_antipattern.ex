defmodule Reach.Smell.Checks.LoopAntipattern do
  @moduledoc false

  use Reach.Smell.Check

  defp findings(function) do
    all_nodes = IR.all_nodes(function)

    append_in_loop(all_nodes, function) ++
      concat_in_loop(all_nodes, function) ++
      manual_min_reduce(all_nodes) ++
      manual_max_reduce(all_nodes) ++
      manual_sum_reduce(all_nodes) ++
      manual_frequencies(all_nodes)
  end

  defp append_in_loop(all_nodes, function) do
    for node <- all_nodes,
        node.type == :binary_op,
        node.meta[:operator] == :++,
        node.source_span,
        Helpers.inside_loop?(node, function) do
      finding(
        :suboptimal,
        "++ inside loop is O(n²); prepend with [item | acc] and Enum.reverse/1 after",
        node
      )
    end
  end

  defp concat_in_loop(all_nodes, function) do
    for node <- all_nodes,
        node.type == :binary_op,
        node.meta[:operator] == :<>,
        node.source_span,
        Helpers.inside_loop?(node, function) do
      finding(:string_building, "<> inside loop is O(n²); use iolists or Enum.map_join", node)
    end
  end

  defp manual_min_reduce(all_nodes) do
    for node <- all_nodes, reduce_call?(node), callback_contains?(node, :min) do
      finding(:suboptimal, "manual min-reduction; use Enum.min/1 or Enum.min_by/2", node)
    end
  end

  defp manual_max_reduce(all_nodes) do
    for node <- all_nodes, reduce_call?(node), callback_contains?(node, :max) do
      finding(:suboptimal, "manual max-reduction; use Enum.max/1 or Enum.max_by/2", node)
    end
  end

  defp manual_sum_reduce(all_nodes) do
    for node <- all_nodes, reduce_call?(node), callback_sum?(node) do
      finding(
        :suboptimal,
        "manual sum-reduction; use Enum.sum/1 or Enum.reduce(list, 0, &+/2)",
        node
      )
    end
  end

  defp manual_frequencies(all_nodes) do
    for node <- all_nodes, reduce_call?(node), frequencies_pattern?(node) do
      finding(:suboptimal, "manual frequency counting; use Enum.frequencies/1", node)
    end
  end

  defp reduce_call?(%{type: :call, meta: %{module: Enum, function: :reduce}, source_span: span})
       when not is_nil(span),
       do: true

  defp reduce_call?(_), do: false

  defp callback_contains?(call, target_fn) do
    call
    |> Helpers.callback_body()
    |> Enum.any?(&(&1.type == :call and &1.meta[:function] == target_fn))
  end

  defp callback_sum?(call) do
    Helpers.callback_body(call)
    |> Enum.any?(&(&1.type == :binary_op and &1.meta[:operator] == :+))
  end

  defp frequencies_pattern?(call) do
    empty_map_acc?(call) and callback_has_map_update?(call)
  end

  defp empty_map_acc?(%{children: children}) do
    Enum.any?(children, &(&1.type == :map and &1.children == []))
  end

  defp callback_has_map_update?(call) do
    Helpers.callback_body(call)
    |> Enum.any?(fn node ->
      node.type == :call and node.meta[:module] == Map and
        node.meta[:function] in [:update, :update!]
    end)
  end
end
