defmodule Reach.CLI.Analyses.Smell.FixedShapeMap do
  @moduledoc false

  @behaviour Reach.CLI.Analyses.Smell.Check

  alias Reach.CLI.Analyses.Smell.Finding
  alias Reach.CLI.Format
  alias Reach.IR

  @min_keys 3
  @min_occurrences 3
  @ignored_keys MapSet.new([:__struct__])

  @impl true
  def run(project) do
    project.nodes
    |> Map.values()
    |> Enum.filter(&(&1.type == :function_def))
    |> Enum.flat_map(&maps_in_function/1)
    |> Enum.group_by(& &1.keys)
    |> Enum.flat_map(&fixed_shape_finding/1)
  end

  defp maps_in_function(function) do
    function
    |> IR.all_nodes()
    |> Enum.filter(&(&1.type == :map and &1.source_span))
    |> Enum.flat_map(&map_shape/1)
  end

  defp map_shape(node) do
    keys =
      node.children
      |> Enum.flat_map(&field_key/1)
      |> Enum.reject(&MapSet.member?(@ignored_keys, &1))
      |> Enum.sort()

    if length(keys) >= @min_keys do
      [%{keys: keys, location: Format.location(node)}]
    else
      []
    end
  end

  defp field_key(%{type: :map_field, children: [%{type: :literal, meta: %{value: key}} | _]})
       when is_atom(key) do
    [key]
  end

  defp field_key(_field), do: []

  defp fixed_shape_finding({keys, occurrences}) do
    occurrence_count = length(occurrences)

    if occurrence_count >= @min_occurrences do
      locations = occurrences |> Enum.map(& &1.location) |> Enum.uniq()

      [
        Finding.new(
          kind: :fixed_shape_map,
          message:
            "map shape #{inspect(keys)} appears #{occurrence_count} times; consider a struct or explicit contract if it is domain data",
          location: List.first(locations),
          evidence: Enum.take(locations, 10),
          keys: Enum.map(keys, &to_string/1),
          occurrences: occurrence_count
        )
      ]
    else
      []
    end
  end
end
