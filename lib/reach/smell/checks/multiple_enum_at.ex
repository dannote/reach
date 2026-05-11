defmodule Reach.Smell.Checks.MultipleEnumAt do
  @moduledoc "Detects multiple Enum.at/2 calls on the same variable with literal indices."

  use Reach.Smell.Check

  @min_calls 3

  defp findings(function) do
    function
    |> leaf_bodies()
    |> Enum.flat_map(&find_in_body/1)
  end

  defp find_in_body(body_nodes) do
    enum_at_calls =
      for node <- body_nodes,
          node.type == :call,
          node.meta[:module] == Enum,
          node.meta[:function] == :at,
          not is_nil(node.source_span),
          [%{type: :var, meta: %{name: var}}, %{type: :literal} | _] <- [node.children] do
        {var, node}
      end

    enum_at_calls
    |> Enum.group_by(&elem(&1, 0))
    |> Enum.filter(fn {_var, calls} -> length(calls) >= @min_calls end)
    |> Enum.map(fn {var, calls} ->
      finding(
        :suboptimal,
        "Enum.at/2 called #{length(calls)} times on `#{var}` with literal indices; use pattern matching to destructure in one pass",
        List.first(calls) |> elem(1)
      )
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
