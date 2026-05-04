defmodule Reach.Smell.Checks.PipelineWaste do
  @moduledoc false

  use Reach.Smell.Check

  alias Reach.Effects

  defp findings(func) do
    all_nodes = IR.all_nodes(func)
    calls = Enum.filter(all_nodes, &pipeline_call?/1)

    sorted =
      Enum.sort_by(calls, fn n -> {n.source_span[:start_line], n.source_span[:start_col] || 0} end)

    find_pipeline_patterns(sorted) ++ detect_string_building(calls, all_nodes)
  end

  defp pipeline_call?(node) do
    node.type == :call and node.source_span != nil and node.meta[:function] != nil and
      (node.meta[:module] in [Enum, Stream, List] or
         (node.meta[:module] == nil and node.meta[:function] == :length))
  end

  defp find_pipeline_patterns(calls) do
    calls
    |> Enum.chunk_every(2, 1, [])
    |> Enum.flat_map(fn
      [first, second] -> check_pair(first, second)
      _ -> []
    end)
  end

  defp check_pair(first, second) do
    if data_connected?(first, second), do: detect_pattern(first, second), else: []
  end

  defp detect_pattern(first, second) do
    pattern = classify_pair(first, second)
    if pattern, do: [smell_for_pattern(pattern, second)], else: []
  end

  defp data_connected?(first, second) do
    first.id in Enum.map(second.children, & &1.id) or
      Enum.any?(second.children, fn child ->
        first.id in Enum.map(child.children, & &1.id)
      end)
  rescue
    _ -> false
  end

  defp reverse_pair?(a, b) do
    a.meta[:function] == :reverse and b.meta[:function] == :reverse and
      a.meta[:arity] == 1 and b.meta[:arity] == 1
  end

  defp filter_count?(a, b), do: a.meta[:function] == :filter and b.meta[:function] == :count
  defp map_count?(a, b), do: a.meta[:function] == :map and b.meta[:function] == :count

  defp map_map?(a, b) do
    a.meta[:function] == :map and b.meta[:function] == :map and a.meta[:module] == b.meta[:module] and
      callbacks_pure?(a) and callbacks_pure?(b)
  end

  defp callbacks_pure?(call) do
    call.children
    |> Enum.filter(&(&1.type in [:fn, :call]))
    |> Enum.all?(fn child ->
      child
      |> IR.all_nodes()
      |> Enum.filter(&(&1.type == :call))
      |> Enum.all?(&Effects.pure?/1)
    end)
  end

  defp filter_filter?(a, b), do: a.meta[:function] == :filter and b.meta[:function] == :filter

  # --- Eager patterns (absorbed from EagerPattern) ---

  defp classify_pair(first, second) do
    pair_pattern(first, second) || sequence_pattern(first, second)
  end

  defp pair_pattern(first, second) do
    cond do
      reverse_pair?(first, second) -> :reverse_reverse
      filter_count?(first, second) -> :filter_count
      map_count?(first, second) -> :map_count
      map_map?(first, second) -> :map_map
      filter_filter?(first, second) -> :filter_filter
      true -> nil
    end
  end

  defp sequence_pattern(first, second) do
    cond do
      map_first?(first, second) -> :map_first
      sort_take?(first, second) -> :sort_take
      sort_reverse?(first, second) -> :sort_reverse
      sort_at?(first, second) -> :sort_at
      drop_take?(first, second) -> :drop_take
      take_while_count?(first, second) -> :take_while_count
      map_join?(first, second) -> :map_join
      true -> nil
    end
  end

  defp map_first?(a, b), do: a.meta[:function] == :map and b.meta[:function] == :first
  defp sort_take?(a, b), do: a.meta[:function] == :sort and b.meta[:function] == :take
  defp sort_reverse?(a, b), do: a.meta[:function] == :sort and b.meta[:function] == :reverse
  defp sort_at?(a, b), do: a.meta[:function] == :sort and b.meta[:function] == :at

  defp drop_take?(a, b) do
    a.meta[:function] == :drop and b.meta[:function] == :take and non_negative_drop?(a)
  end

  defp take_while_count?(a, b),
    do: a.meta[:function] == :take_while and b.meta[:function] in [:count, :length]

  defp map_join?(a, b), do: a.meta[:function] == :map and b.meta[:function] == :join

  defp non_negative_drop?(%{children: [_enum, %{type: :literal, meta: %{value: amount}}]})
       when is_integer(amount),
       do: amount >= 0

  defp non_negative_drop?(%{children: [_enum, %{type: :unary_op, meta: %{operator: :-}}]}),
    do: false

  defp non_negative_drop?(_call), do: true

  defp smell_for_pattern(:reverse_reverse, node) do
    finding(:redundant_traversal, "Enum.reverse → Enum.reverse is a no-op", node)
  end

  defp smell_for_pattern(:filter_count, node) do
    finding(:suboptimal, "Enum.filter → Enum.count: use Enum.count/2 instead", node)
  end

  defp smell_for_pattern(:map_count, node) do
    finding(:suboptimal, "Enum.map → Enum.count: use Enum.count/2 with transform", node)
  end

  defp smell_for_pattern(:map_map, node) do
    finding(:suboptimal, "Enum.map → Enum.map: consider fusing into one pass", node)
  end

  defp smell_for_pattern(:filter_filter, node) do
    finding(:suboptimal, "Enum.filter → Enum.filter: combine predicates into one pass", node)
  end

  defp smell_for_pattern(:map_first, node) do
    finding(
      :eager_pattern,
      "Enum.map → List.first: builds entire list for one element. Use Enum.find_value/2",
      node
    )
  end

  defp smell_for_pattern(:sort_take, node) do
    finding(
      :eager_pattern,
      "Enum.sort → Enum.take: sorts entire list. Use Enum.min/max for one element or a partial top-k pass",
      node
    )
  end

  defp smell_for_pattern(:sort_reverse, node) do
    finding(
      :eager_pattern,
      "Enum.sort → Enum.reverse: use Enum.sort(enumerable, :desc) instead",
      node
    )
  end

  defp smell_for_pattern(:sort_at, node) do
    finding(
      :eager_pattern,
      "Enum.sort → Enum.at: full sort for one element. Use Enum.min/max or a selection pass",
      node
    )
  end

  defp smell_for_pattern(:drop_take, node) do
    finding(
      :eager_pattern,
      "Enum.drop → Enum.take: use Enum.slice/3 to express slicing intent",
      node
    )
  end

  defp smell_for_pattern(:take_while_count, node) do
    finding(
      :eager_pattern,
      "Enum.take_while → count/length: allocates an intermediate list. Use Enum.reduce_while/3",
      node
    )
  end

  defp smell_for_pattern(:map_join, node) do
    finding(
      :eager_pattern,
      "Enum.map → Enum.join: use Enum.map_join/3 when the intended result is a binary",
      node
    )
  end

  # --- String building (absorbed from StringBuilding) ---

  defp detect_string_building(calls, all_nodes) do
    detect_map_join_interpolation(calls) ++
      detect_map_join_concat(calls) ++
      detect_concat_around_join(all_nodes) ++
      detect_reduce_string_concat(calls)
  end

  defp detect_map_join_interpolation(calls) do
    calls
    |> Enum.filter(&enum_call?(&1, :join))
    |> Enum.flat_map(&map_join_interpolation_smell(&1, calls))
  end

  defp map_join_interpolation_smell(join, calls) do
    with %{meta: %{function: :map, module: Enum}} = map_call <- find_piped_producer(join, calls),
         true <- callback_builds_strings?(map_call) do
      [
        finding(
          :string_building,
          "Enum.map(& \"...#{}\"\) |> Enum.join: builds intermediate strings. Return iolists from map and pass to IO directly",
          join
        )
      ]
    else
      _ -> []
    end
  end

  defp detect_map_join_concat(calls) do
    calls
    |> Enum.filter(&(enum_call?(&1, :map_join) and callback_builds_strings?(&1)))
    |> Enum.map(fn call ->
      finding(
        :string_building,
        "Enum.map_join with string interpolation: builds N intermediate strings. Use Enum.map/2 returning iolists",
        call
      )
    end)
  end

  defp detect_concat_around_join(all_nodes) do
    concat_ids_with_join =
      Enum.filter(all_nodes, fn node ->
        node.type == :binary_op and node.meta[:operator] == :<> and node.source_span != nil and
          Enum.any?(IR.all_nodes(node), &enum_call?(&1, :join))
      end)

    nested_ids =
      concat_ids_with_join
      |> Enum.flat_map(fn concat -> Enum.map(concat.children, & &1.id) end)
      |> MapSet.new()

    concat_ids_with_join
    |> Enum.reject(&(&1.id in nested_ids))
    |> Enum.map(fn concat ->
      finding(
        :string_building,
        "String concatenation around Enum.join: wrap in a list instead — [\"<div>\", parts, \"</div>\"]",
        concat
      )
    end)
  end

  defp detect_reduce_string_concat(calls) do
    calls
    |> Enum.filter(fn reduce ->
      enum_call?(reduce, :reduce) and has_empty_string_acc?(reduce) and
        callback_uses_string_concat?(reduce)
    end)
    |> Enum.map(fn reduce ->
      finding(
        :string_building,
        "Enum.reduce building string with <>: O(n²) copying. Use iolists or Enum.map_join",
        reduce
      )
    end)
  end

  defp enum_call?(%{type: :call, meta: %{module: Enum, function: function}}, target),
    do: function == target

  defp enum_call?(_node, _target), do: false

  defp find_piped_producer(consumer, calls) do
    Enum.find(calls, fn candidate ->
      candidate.id in Enum.map(consumer.children, & &1.id)
    end)
  end

  defp callback_builds_strings?(call) do
    call.children
    |> Enum.filter(&(&1.type == :fn))
    |> Enum.any?(fn fn_node ->
      subtree = IR.all_nodes(fn_node)
      has_interpolation?(subtree) or has_concat?(subtree)
    end)
  end

  defp has_interpolation?(nodes) do
    Enum.any?(nodes, fn node ->
      node.type == :call and node.meta[:function] == :<<>> and node.meta[:kind] == :local
    end)
  end

  defp has_concat?(nodes) do
    Enum.any?(nodes, fn node ->
      node.type == :binary_op and node.meta[:operator] == :<>
    end)
  end

  defp has_empty_string_acc?(%{children: children}) do
    Enum.any?(children, fn
      %{type: :literal, meta: %{value: ""}} -> true
      _ -> false
    end)
  end

  defp callback_uses_string_concat?(reduce) do
    reduce.children
    |> Enum.filter(&(&1.type == :fn))
    |> Enum.any?(fn fn_node ->
      subtree = IR.all_nodes(fn_node)
      has_concat?(subtree) or has_interpolation?(subtree)
    end)
  end
end
