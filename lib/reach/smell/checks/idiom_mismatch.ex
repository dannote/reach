defmodule Reach.Smell.Checks.IdiomMismatch do
  @moduledoc false

  use Reach.Smell.Check

  defp findings(function) do
    guard_equality_findings(function) ++ map_update_then_fetch(function)
  end

  defp guard_equality_findings(function) do
    function.children
    |> Enum.filter(&(&1.type == :clause and &1.meta[:kind] == :function_clause))
    |> Enum.flat_map(&guard_equalities/1)
  end

  defp guard_equalities(clause) do
    clause
    |> IR.all_nodes()
    |> Enum.filter(&guard_with_literal_equality?/1)
    |> Enum.map(
      &finding(
        :suboptimal,
        "guard compares parameter to literal with ==; use pattern matching in the function head",
        &1
      )
    )
  end

  defp guard_with_literal_equality?(%{type: :guard} = guard) do
    guard
    |> IR.all_nodes()
    |> Enum.any?(fn node ->
      node.type == :binary_op and node.meta[:operator] == :== and
        has_literal_and_var?(node.children)
    end)
  end

  defp guard_with_literal_equality?(_), do: false

  defp has_literal_and_var?([left, right]) do
    (literal?(left) and var?(right)) or (var?(left) and literal?(right))
  end

  defp has_literal_and_var?(_), do: false

  defp literal?(%{type: :literal, meta: %{value: v}})
       when is_atom(v) or is_integer(v) or is_binary(v), do: true

  defp literal?(_), do: false

  defp var?(%{type: :var}), do: true
  defp var?(_), do: false

  defp map_update_then_fetch(function) do
    Helpers.statement_pairs(function)
    |> Enum.flat_map(fn {first, second} ->
      update_var = map_update_binding(first)
      fetch_var = map_fetch_on(second)

      if update_var && fetch_var && update_var == fetch_var do
        [
          finding(
            :suboptimal,
            "Map.update then Map.get/fetch on same variable traverses twice; compute value first with Map.get, then Map.put",
            second
          )
        ]
      else
        []
      end
    end)
  end

  defp map_update_binding(%{type: :match, children: [%{type: :var, meta: %{name: var}}, call]}) do
    if call.type == :call and call.meta[:module] == Map and
         call.meta[:function] in [:update, :update!] do
      var
    end
  end

  defp map_update_binding(_), do: nil

  defp map_fetch_on(node) do
    node
    |> IR.all_nodes()
    |> Enum.find_value(&map_fetch_var/1)
  end

  defp map_fetch_var(%{
         type: :call,
         meta: %{module: Map, function: f},
         children: [%{type: :var, meta: %{name: var}} | _]
       })
       when f in [:get, :fetch, :fetch!],
       do: var

  defp map_fetch_var(_), do: nil
end
