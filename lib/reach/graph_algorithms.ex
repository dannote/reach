defmodule Reach.GraphAlgorithms do
  @moduledoc false

  def cycle_components(graph, canonical_fun \\ &default_canonical/1) do
    graph
    |> Graph.strong_components()
    |> Enum.filter(&match?([_, _ | _], &1))
    |> Enum.map(canonical_fun)
    |> Enum.sort_by(&{length(&1), &1})
  end

  defp default_canonical(component), do: Enum.sort(component)
end
