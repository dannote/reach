defmodule Reach.Smell.Checks.CollectionIdioms do
  @moduledoc false

  use Reach.Smell.Check

  alias Reach.IR
  alias Reach.Smell.Finding

  defp findings(function) do
    function
    |> IR.all_nodes()
    |> Enum.filter(& &1.source_span)
    |> Enum.flat_map(&finding_for/1)
  end

  defp finding_for(%{type: :call, meta: %{module: Enum, function: :join, arity: 2}} = node) do
    if empty_string_arg?(node, 1) do
      [
        finding(
          :suboptimal,
          "Enum.join/1 already defaults to an empty string separator; remove the redundant \"\" argument",
          node
        )
      ]
    else
      []
    end
  end

  defp finding_for(%{type: :call, meta: %{module: Enum, function: :take, arity: 2}} = node) do
    case negative_integer_arg(node, 1) do
      nil ->
        []

      count ->
        [
          finding(
            :suboptimal,
            "Enum.take(list, -#{count}) takes from the end and can force extra traversal; prefer sorting/selecting in the desired direction and taking #{count}",
            node
          )
        ]
    end
  end

  defp finding_for(%{type: :call, meta: %{function: function, arity: 1}} = node)
       when function in [:length, :count] do
    if string_graphemes_child?(node) do
      [
        finding(
          :suboptimal,
          "String.graphemes/1 followed by #{call_label(node)} builds an intermediate list; use String.length/1",
          node
        )
      ]
    else
      []
    end
  end

  defp finding_for(
         %{type: :call, meta: %{module: String, function: :to_charlist, arity: 1}} = node
       ) do
    if integer_to_string_child?(node) do
      [
        finding(
          :suboptimal,
          "Integer.to_string/2 followed by String.to_charlist/1 extracts digits via an intermediate binary; prefer integer arithmetic or Integer.digits/2 when available",
          node
        )
      ]
    else
      []
    end
  end

  defp finding_for(%{type: :binary_op, meta: %{operator: operator}} = node)
       when operator in [:==, :!=] do
    if compares_string_length_to_one?(node) do
      [
        finding(
          :suboptimal,
          "String.length/1 traverses the whole string just to check for one character; use pattern matching or String.graphemes/1 with a match",
          node
        )
      ]
    else
      []
    end
  end

  defp finding_for(_node), do: []

  defp empty_string_arg?(%{children: children}, index) do
    match?(%{type: :literal, meta: %{value: ""}}, Enum.at(children, index))
  end

  defp negative_integer_arg(%{children: children}, index) do
    case Enum.at(children, index) do
      %{
        type: :unary_op,
        meta: %{operator: :-},
        children: [%{type: :literal, meta: %{value: value}}]
      }
      when is_integer(value) and value > 0 ->
        value

      _ ->
        nil
    end
  end

  defp string_graphemes_child?(%{
         children: [%{type: :call, meta: %{module: String, function: :graphemes, arity: 1}} | _]
       }),
       do: true

  defp string_graphemes_child?(_node), do: false

  defp integer_to_string_child?(%{
         children: [%{type: :call, meta: %{module: Integer, function: :to_string, arity: 2}} | _]
       }),
       do: true

  defp integer_to_string_child?(_node), do: false

  defp compares_string_length_to_one?(%{children: [left, right]}) do
    (string_length_call?(left) and literal_one?(right)) or
      (literal_one?(left) and string_length_call?(right))
  end

  defp compares_string_length_to_one?(_node), do: false

  defp string_length_call?(%{type: :call, meta: %{module: String, function: :length, arity: 1}}),
    do: true

  defp string_length_call?(_node), do: false

  defp literal_one?(%{type: :literal, meta: %{value: 1}}), do: true
  defp literal_one?(_node), do: false

  defp call_label(%{meta: %{module: Enum, function: :count}}), do: "Enum.count/1"
  defp call_label(%{meta: %{module: nil, function: :length}}), do: "length/1"

  defp finding(kind, message, node) do
    Finding.new(kind: kind, message: message, location: Helpers.location(node))
  end
end
