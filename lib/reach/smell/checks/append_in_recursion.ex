defmodule Reach.Smell.Checks.AppendInRecursion do
  @moduledoc "Detects ++ [item] in recursive tail calls where prepend + reverse would be O(n) instead of O(n²)."

  use Reach.Smell.Check

  defp findings(function) do
    name = function.meta[:name]
    arity = function.meta[:arity]

    if name && arity && Helpers.recursive?(function) do
      all_nodes = IR.all_nodes(function)

      self_calls =
        Enum.filter(all_nodes, fn n ->
          n.type == :call and n.meta[:function] == name and
            n.meta[:arity] == arity and n.meta[:module] == nil
        end)

      Enum.flat_map(self_calls, fn call ->
        call.children
        |> Enum.filter(fn arg ->
          arg.type == :binary_op and arg.meta[:operator] == :++ and
            match?([_, %{type: :list}], arg.children)
        end)
        |> Enum.map(fn append_node ->
          finding(
            :suboptimal,
            "++ [item] in recursive call is O(n²); prepend with [item | acc] and Enum.reverse/1 in the base case",
            (append_node.source_span && append_node) || function
          )
        end)
      end)
    else
      []
    end
  end
end
