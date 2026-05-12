defmodule Reach.Smell.Checks.RedundantAssignment do
  @moduledoc "Detects variables assigned then immediately returned as the last expression."

  use Reach.Smell.Check

  defp findings(function) do
    Helpers.statement_pairs(function)
    |> Enum.flat_map(fn {first, second} ->
      with {:ok, var} <- simple_var_assignment(first),
           true <- last_statement?(second, function),
           true <- same_var_return?(second, var) do
        [
          finding(
            :suboptimal,
            "`#{var}` assigned then immediately returned; the assignment is unnecessary",
            first
          )
        ]
      else
        _ -> []
      end
    end)
  end

  defp simple_var_assignment(%{type: :match, children: [%{type: :var, meta: %{name: var}}, _]}),
    do: {:ok, var}

  defp simple_var_assignment(_), do: :error

  defp same_var_return?(%{type: :var, meta: %{name: var}}, var), do: true
  defp same_var_return?(_, _), do: false

  defp last_statement?(node, function) do
    statements = body_statements(function)
    List.last(statements) == node
  end

  defp body_statements(function) do
    case function.children do
      [%{type: :clause, children: children} | _] ->
        children
        |> Enum.reject(&(&1.type in [:guard]))
        |> Enum.drop(function.meta[:arity] || 0)
        |> Enum.flat_map(&unwrap_block/1)

      children ->
        children
    end
  end

  defp unwrap_block(%{type: :block, children: children}), do: children
  defp unwrap_block(node), do: [node]
end
