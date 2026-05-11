defmodule Reach.Smell.Checks.AppendInRecursion do
  @moduledoc "Detects ++ [item] in recursive tail calls where prepend + reverse would be O(n) instead of O(n²)."

  use Reach.Smell.Check

  defp findings(function) do
    name = function.meta[:name]
    arity = function.meta[:arity]

    if name && arity && Helpers.recursive?(function) do
      function
      |> IR.all_nodes()
      |> Enum.filter(&self_call?(&1, name, arity))
      |> Enum.flat_map(&append_args(&1, function))
    else
      []
    end
  end

  defp self_call?(node, name, arity) do
    node.type == :call and node.meta[:function] == name and
      node.meta[:arity] == arity and node.meta[:module] == nil
  end

  defp append_args(call, function) do
    call.children
    |> Enum.filter(&list_append?/1)
    |> Enum.map(fn node ->
      finding(
        :suboptimal,
        "++ [item] in recursive call is O(n²); prepend with [item | acc] and Enum.reverse/1 in the base case",
        (node.source_span && node) || function
      )
    end)
  end

  defp list_append?(%{type: :binary_op, meta: %{operator: :++}, children: [_, %{type: :list}]}),
    do: true

  defp list_append?(_), do: false
end
