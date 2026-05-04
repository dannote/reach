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

  defp finding_for(%{type: :call, meta: %{module: nil, function: :hd, arity: 1}} = node) do
    if reverse_child?(node) do
      [
        finding(
          :suboptimal,
          "Enum.reverse/1 |> hd() traverses the list twice; use List.last/1",
          node
        )
      ]
    else
      []
    end
  end

  defp finding_for(%{type: :call, meta: %{module: List, function: :first, arity: 1}} = node) do
    if reverse_child?(node) do
      [
        finding(
          :suboptimal,
          "Enum.reverse/1 |> List.first/1 traverses the list twice; use List.last/1",
          node
        )
      ]
    else
      []
    end
  end

  defp finding_for(%{type: :binary_op, meta: %{operator: :++}, source_span: span} = node)
       when not is_nil(span) do
    case node.children do
      [%{type: :call, meta: %{module: Enum, function: :reverse, arity: 1}}, _tail] ->
        [
          finding(
            :suboptimal,
            "Enum.reverse(list) ++ tail traverses twice; use Enum.reverse(list, tail)",
            node
          )
        ]

      _ ->
        []
    end
  end

  defp finding_for(
         %{type: :call, meta: %{module: String, function: :starts_with?, arity: 2}} = node
       ) do
    if inspect_pipe_source?(node) do
      [
        finding(
          :suboptimal,
          "inspect/1 for module/atom membership is fragile; use Module.split/1 or direct atom comparison",
          node
        )
      ]
    else
      []
    end
  end

  defp finding_for(%{type: :call, meta: %{module: String, function: :contains?, arity: 2}} = node) do
    if inspect_pipe_source?(node) do
      [
        finding(
          :suboptimal,
          "inspect/1 for type checking is fragile; compare atoms or use Module.split/1",
          node
        )
      ]
    else
      []
    end
  end

  defp finding_for(%{type: :call, meta: %{module: String, function: :replace, arity: 3}} = node) do
    if chained_replace_sibling?(node) do
      [
        finding(
          :suboptimal,
          "chained String.replace/3 with single-char literals; use a single Regex.replace/3 or String.replace/3 with a regex",
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

  defp reverse_child?(%{
         children: [%{type: :call, meta: %{module: Enum, function: :reverse}} | _]
       }),
       do: true

  defp reverse_child?(%{children: [%{type: :call, meta: %{function: :reverse}} | _]}), do: true
  defp reverse_child?(_node), do: false

  defp inspect_pipe_source?(%{children: [%{type: :call, meta: %{function: :inspect}} | _]}),
    do: true

  defp inspect_pipe_source?(%{meta: %{desugared_from: :pipe}, children: children}) do
    Enum.any?(children, fn
      %{type: :call, meta: %{function: :inspect}} -> true
      _ -> false
    end)
  end

  defp inspect_pipe_source?(_node), do: false

  defp chained_replace_sibling?(%{children: [source | _]}) do
    match?(%{type: :call, meta: %{module: String, function: :replace}}, source)
  end

  defp chained_replace_sibling?(_node), do: false

  defp finding(kind, message, node) do
    Finding.new(kind: kind, message: message, location: Helpers.location(node))
  end
end
