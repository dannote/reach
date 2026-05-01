defmodule Reach.CLI.Analyses.Smell.StringBuilding do
  @moduledoc false

  use Reach.CLI.Analyses.Smell.Check

  alias Reach.CLI.Analyses.Smell.Finding
  alias Reach.CLI.Format
  alias Reach.IR

  defp findings(func) do
    all = IR.all_nodes(func)
    calls = Enum.filter(all, &(&1.type == :call and &1.source_span != nil))

    detect_map_join_interpolation(calls) ++
      detect_map_join_concat(calls) ++
      detect_concat_around_join(all) ++
      detect_reduce_string_concat(calls)
  end

  defp detect_map_join_interpolation(calls) do
    calls
    |> Enum.filter(&enum_call?(&1, :join))
    |> Enum.flat_map(&map_join_interpolation_smell(&1, calls))
  end

  defp map_join_interpolation_smell(join, calls) do
    case find_piped_producer(join, calls) do
      %{meta: %{function: :map, module: Enum}} = map_call ->
        string_building_smell(
          callback_builds_strings?(map_call),
          "Enum.map(& \"...\#{}\") |> Enum.join: builds intermediate strings. Return iolists from map and pass to IO directly",
          join
        )

      _ ->
        []
    end
  end

  defp string_building_smell(false, _message, _node), do: []

  defp string_building_smell(true, message, node) do
    [
      Finding.new(
        kind: :string_building,
        message: message,
        location: Format.location(node)
      )
    ]
  end

  defp detect_map_join_concat(calls) do
    calls
    |> Enum.filter(&(enum_call?(&1, :map_join) and callback_builds_strings?(&1)))
    |> Enum.map(fn call ->
      Finding.new(
        kind: :string_building,
        message:
          "Enum.map_join with string interpolation: builds N intermediate strings. Use Enum.map/2 returning iolists",
        location: Format.location(call)
      )
    end)
  end

  defp detect_concat_around_join(all) do
    concat_ids_with_join =
      Enum.filter(all, fn node ->
        node.type == :binary_op and node.meta[:operator] == :<> and node.source_span != nil and
          Enum.any?(IR.all_nodes(node), &enum_call?(&1, :join))
      end)

    nested_ids =
      concat_ids_with_join
      |> Enum.flat_map(fn concat -> Enum.map(concat.children, & &1.id) end)
      |> MapSet.new()

    concat_ids_with_join
    |> Enum.reject(fn concat -> concat.id in nested_ids end)
    |> Enum.map(fn concat ->
      Finding.new(
        kind: :string_building,
        message:
          "String concatenation around Enum.join: wrap in a list instead — [\"<div>\", parts, \"</div>\"]",
        location: Format.location(concat)
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
      Finding.new(
        kind: :string_building,
        message:
          "Enum.reduce building string with <>: O(n²) copying. Use iolists or Enum.map_join",
        location: Format.location(reduce)
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
