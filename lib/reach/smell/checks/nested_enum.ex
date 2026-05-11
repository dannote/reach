defmodule Reach.Smell.Checks.NestedEnum do
  @moduledoc "Detects Enum.member? nested inside another Enum traversal of the same variable."

  use Reach.Smell.Check

  @outer_fns ~w(map filter reduce each any? all? find find_value flat_map reject count)a

  defp findings(function) do
    all_nodes = IR.all_nodes(function)

    outer_calls =
      for node <- all_nodes,
          node.type == :call,
          node.meta[:module] == Enum,
          node.meta[:function] in @outer_fns,
          node.source_span,
          [%{type: :var, meta: %{name: var}} | _] <- [node.children] do
        {var, node}
      end

    Enum.flat_map(outer_calls, fn {var, outer} ->
      inner_calls =
        outer
        |> Helpers.callback_body()
        |> Enum.filter(fn n ->
          n.type == :call and n.meta[:module] == Enum and
            n.meta[:function] == :member? and not is_nil(n.source_span) and
            match?([%{type: :var, meta: %{name: ^var}} | _], n.children)
        end)

      Enum.map(inner_calls, fn inner ->
        finding(
          :suboptimal,
          "Enum.member?/2 nested inside Enum.#{outer.meta[:function]} on `#{var}` is O(n²); precompute a MapSet",
          inner
        )
      end)
    end)
  end
end
