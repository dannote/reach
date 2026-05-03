defmodule Reach.Smell.Checks.EagerPattern do
  @moduledoc false

  use Reach.Smell.Check

  alias Reach.IR
  alias Reach.Smell.Finding

  defp findings(func) do
    func
    |> IR.all_nodes()
    |> Enum.filter(&eager_call?/1)
    |> Enum.sort_by(fn n -> {n.source_span[:start_line], n.source_span[:start_col] || 0} end)
    |> Enum.chunk_every(2, 1, [])
    |> Enum.flat_map(&eager_pattern_for_pair/1)
  end

  defp eager_call?(node) do
    node.type == :call and node.source_span != nil and
      (node.meta[:module] in [Enum, List] or
         (node.meta[:module] == nil and node.meta[:function] == :length))
  end

  defp eager_pattern_for_pair([first, second]) do
    if data_connected?(first, second),
      do: eager_pattern_for_connected_pair(first, second),
      else: []
  end

  defp eager_pattern_for_pair(_), do: []

  defp eager_pattern_for_connected_pair(
         %{meta: %{function: :map}},
         %{meta: %{function: :first}} = second
       ),
       do: [map_first_smell(second)]

  defp eager_pattern_for_connected_pair(
         %{meta: %{function: :sort}},
         %{meta: %{function: :take}} = second
       ),
       do: [sort_take_smell(second)]

  defp eager_pattern_for_connected_pair(
         %{meta: %{function: :sort}},
         %{meta: %{function: :reverse}} = second
       ),
       do: [sort_reverse_smell(second)]

  defp eager_pattern_for_connected_pair(
         %{meta: %{function: :sort}},
         %{meta: %{function: :at}} = second
       ),
       do: [sort_at_smell(second)]

  defp eager_pattern_for_connected_pair(
         %{meta: %{function: :drop}} = first,
         %{meta: %{function: :take}} = second
       ) do
    if non_negative_drop?(first), do: [drop_take_smell(second)], else: []
  end

  defp eager_pattern_for_connected_pair(
         %{meta: %{function: :take_while}},
         %{meta: %{function: function}} = second
       )
       when function in [:count, :length],
       do: [take_while_count_smell(second)]

  defp eager_pattern_for_connected_pair(
         %{meta: %{function: :map}},
         %{meta: %{function: :join}} = second
       ),
       do: [map_join_smell(second)]

  defp eager_pattern_for_connected_pair(_first, _second), do: []

  defp data_connected?(first, second) do
    first.id in Enum.map(second.children, & &1.id) or
      Enum.any?(second.children, fn child ->
        first.id in Enum.map(child.children, & &1.id)
      end)
  rescue
    _ -> false
  end

  defp map_first_smell(second) do
    Finding.new(
      kind: :eager_pattern,
      message: "Enum.map → List.first: builds entire list for one element. Use Enum.find_value/2",
      location: Helpers.location(second)
    )
  end

  defp sort_take_smell(second) do
    Finding.new(
      kind: :eager_pattern,
      message:
        "Enum.sort → Enum.take(#{take_count(second)}): sorts entire list. Use Enum.min/max for one element or a partial top-k pass",
      location: Helpers.location(second)
    )
  end

  defp sort_reverse_smell(second) do
    Finding.new(
      kind: :eager_pattern,
      message: "Enum.sort → Enum.reverse: use Enum.sort(enumerable, :desc) instead",
      location: Helpers.location(second)
    )
  end

  defp sort_at_smell(second) do
    Finding.new(
      kind: :eager_pattern,
      message:
        "Enum.sort → Enum.at(#{take_count(second)}): full sort for one element. Use Enum.min/max or a selection pass",
      location: Helpers.location(second)
    )
  end

  defp non_negative_drop?(%{children: [_enum, %{type: :literal, meta: %{value: amount}}]})
       when is_integer(amount),
       do: amount >= 0

  defp non_negative_drop?(%{children: [_enum, %{type: :unary_op, meta: %{operator: :-}}]}),
    do: false

  defp non_negative_drop?(_call), do: true

  defp drop_take_smell(second) do
    Finding.new(
      kind: :eager_pattern,
      message: "Enum.drop → Enum.take: use Enum.slice/3 to express slicing intent",
      location: Helpers.location(second)
    )
  end

  defp take_while_count_smell(second) do
    Finding.new(
      kind: :eager_pattern,
      message:
        "Enum.take_while → count/length: allocates an intermediate list. Use Enum.all?/2 or Enum.reduce_while/3",
      location: Helpers.location(second)
    )
  end

  defp map_join_smell(second) do
    Finding.new(
      kind: :eager_pattern,
      message: "Enum.map → Enum.join: use Enum.map_join/3 when the intended result is a binary",
      location: Helpers.location(second)
    )
  end

  defp take_count(node) do
    case node.children do
      [_, %{type: :literal, meta: %{value: n}}] -> n
      _ -> "?"
    end
  end
end
