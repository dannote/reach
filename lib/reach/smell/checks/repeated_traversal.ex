defmodule Reach.Smell.Checks.RepeatedTraversal do
  @moduledoc "Detects repeated Enum traversals on the same variable."

  use Reach.Smell.Check

  @single_pass_fns ~w(count max min sum member? any? all? find find_value)a

  defp findings(function) do
    function
    |> leaf_bodies()
    |> Enum.flat_map(&find_in_body/1)
  end

  defp find_in_body(body_nodes) do
    enum_calls =
      for node <- body_nodes,
          node.type == :call,
          node.meta[:module] == Enum,
          node.meta[:function] in @single_pass_fns,
          not is_nil(node.source_span),
          [%{type: :var, meta: %{name: var}} | _] <- [node.children] do
        {var, node}
      end

    enum_calls
    |> Enum.group_by(&elem(&1, 0))
    |> Enum.flat_map(fn {var, calls} ->
      unique_fns = calls |> Enum.map(fn {_, n} -> n.meta[:function] end) |> Enum.uniq()

      if length(unique_fns) >= 2 do
        fns = Enum.map_join(unique_fns, ", ", &"Enum.#{&1}")

        [
          finding(
            :suboptimal,
            "`#{var}` traversed #{length(calls)} times (#{fns}); combine into a single Enum.reduce/3",
            List.first(calls) |> elem(1)
          )
        ]
      else
        []
      end
    end)
  end

  defp leaf_bodies(function) do
    function.children
    |> Enum.filter(&(&1.type == :clause))
    |> case do
      [] -> [IR.all_nodes(function)]
      clauses -> Enum.map(clauses, &IR.all_nodes/1)
    end
  end
end
