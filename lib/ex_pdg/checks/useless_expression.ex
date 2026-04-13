defmodule ExPDG.Checks.UselessExpression do
  @moduledoc """
  Detects pure function calls whose result is obviously unused.

  Only flags calls that are direct children of a block and have no
  data dependents. Very conservative to avoid false positives.
  """

  @behaviour ExPDG.Check

  @impl true
  def meta, do: %{severity: :warning, category: :code_quality}

  @impl true
  def run(graph, _opts) do
    import ExPDG.Query

    all = nodes(graph)
    non_last_block_children = collect_non_last_block_children(all)

    for node <- all,
        node.type == :call,
        node.id in non_last_block_children,
        pure?(node) do
      %ExPDG.Diagnostic{
        check: :useless_expression,
        severity: :warning,
        category: :code_quality,
        message: "Pure function call result is unused",
        location: node.source_span,
        node_id: node.id
      }
    end
  end

  defp collect_non_last_block_children(all_nodes) do
    all_nodes
    |> Enum.filter(&(&1.type == :block))
    |> Enum.flat_map(fn block ->
      block.children
      |> Enum.drop(-1)
      |> Enum.map(& &1.id)
    end)
    |> MapSet.new()
  end
end
