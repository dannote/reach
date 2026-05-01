defmodule Reach.CLI.Analyses.Smell.PipelineWaste do
  @moduledoc false

  @behaviour Reach.CLI.Analyses.Smell.Check

  alias Reach.CLI.Analyses.Smell.Finding
  alias Reach.CLI.Format
  alias Reach.Effects
  alias Reach.IR

  @impl true
  def run(project) do
    project.nodes
    |> Map.values()
    |> Enum.filter(&(&1.type == :function_def))
    |> Enum.flat_map(&findings/1)
  end

  defp findings(func) do
    func
    |> IR.all_nodes()
    |> Enum.filter(&pipeline_call?/1)
    |> Enum.sort_by(fn n -> {n.source_span[:start_line], n.source_span[:start_col] || 0} end)
    |> find_pipeline_patterns()
  end

  defp pipeline_call?(node) do
    node.type == :call and node.meta[:module] in [Enum, Stream] and
      node.meta[:kind] != :fun_ref and node.meta[:function] != nil and node.source_span != nil
  end

  defp find_pipeline_patterns(calls) do
    calls
    |> Enum.chunk_every(2, 1, [])
    |> Enum.flat_map(fn
      [first, second] -> check_pair(first, second)
      _ -> []
    end)
  end

  defp check_pair(first, second) do
    if data_connected?(first, second), do: detect_pattern(first, second), else: []
  end

  defp detect_pattern(first, second) do
    pattern = classify_pair(first, second)
    if pattern, do: [smell_for_pattern(pattern, second)], else: []
  end

  defp classify_pair(first, second) do
    cond do
      reverse_pair?(first, second) -> :reverse_reverse
      filter_count?(first, second) -> :filter_count
      map_count?(first, second) -> :map_count
      map_map?(first, second) -> :map_map
      filter_filter?(first, second) -> :filter_filter
      true -> nil
    end
  end

  defp smell_for_pattern(:reverse_reverse, node) do
    Finding.new(
      kind: :redundant_traversal,
      message: "Enum.reverse → Enum.reverse is a no-op",
      location: Format.location(node)
    )
  end

  defp smell_for_pattern(:filter_count, node) do
    Finding.new(
      kind: :suboptimal,
      message: "Enum.filter → Enum.count: use Enum.count/2 instead",
      location: Format.location(node)
    )
  end

  defp smell_for_pattern(:map_count, node) do
    Finding.new(
      kind: :suboptimal,
      message: "Enum.map → Enum.count: use Enum.count/2 with transform",
      location: Format.location(node)
    )
  end

  defp smell_for_pattern(:map_map, node) do
    Finding.new(
      kind: :suboptimal,
      message: "Enum.map → Enum.map: consider fusing into one pass",
      location: Format.location(node)
    )
  end

  defp smell_for_pattern(:filter_filter, node) do
    Finding.new(
      kind: :suboptimal,
      message: "Enum.filter → Enum.filter: combine predicates into one pass",
      location: Format.location(node)
    )
  end

  defp data_connected?(first, second) do
    first.id in Enum.map(second.children, & &1.id) or
      Enum.any?(second.children, fn child ->
        first.id in Enum.map(child.children, & &1.id)
      end)
  rescue
    _ -> false
  end

  defp reverse_pair?(a, b) do
    a.meta[:function] == :reverse and b.meta[:function] == :reverse and
      a.meta[:arity] == 1 and b.meta[:arity] == 1
  end

  defp filter_count?(a, b), do: a.meta[:function] == :filter and b.meta[:function] == :count
  defp map_count?(a, b), do: a.meta[:function] == :map and b.meta[:function] == :count

  defp map_map?(a, b) do
    a.meta[:function] == :map and b.meta[:function] == :map and a.meta[:module] == b.meta[:module] and
      callbacks_pure?(a) and callbacks_pure?(b)
  end

  defp callbacks_pure?(call) do
    call.children
    |> Enum.filter(&(&1.type in [:fn, :call]))
    |> Enum.all?(fn child ->
      child
      |> IR.all_nodes()
      |> Enum.filter(&(&1.type == :call))
      |> Enum.all?(&Effects.pure?/1)
    end)
  end

  defp filter_filter?(a, b), do: a.meta[:function] == :filter and b.meta[:function] == :filter
end
