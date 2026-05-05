defmodule Reach.Trace.Slice do
  @moduledoc "Backward and forward program slicing from a source location."

  alias Reach.Project.Query
  alias Reach.Trace.Slice.{Result, Statement}

  def compute(project, node, opts \\ []) do
    forward? = Keyword.get(opts, :forward, false)
    var_name = Keyword.get(opts, :variable)
    limit = Keyword.fetch!(opts, :limit)

    slice_ids = slice_ids(project.graph, node.id, forward?)
    statements = statements(project, slice_ids, var_name, limit)

    Result.new(
      node: node,
      direction: if(forward?, do: :forward, else: :backward),
      statements: statements
    )
  end

  def find_node_at_location(project, file, line) do
    target_basename = Path.basename(file)

    for(
      {_id, node} <- project.nodes,
      %{file: source_file, start_line: start_line} <- [node.source_span],
      Query.file_matches?(source_file, file) and start_line == line,
      not (source_file != file and source_file != target_basename),
      do: node
    )
    |> Enum.min_by(&node_specificity/1, fn -> nil end)
  end

  def describe_node(node) do
    case node.type do
      :var ->
        "var #{node.meta[:name]}"

      :call ->
        mod = node.meta[:module]
        fun = node.meta[:function]
        if mod && fun, do: "#{inspect(mod)}.#{fun}", else: "call"

      :match ->
        "match"

      :literal ->
        inspect(node.meta[:value])

      other ->
        to_string(other)
    end
  end

  defp slice_ids(graph, node_id, forward?) do
    if Graph.has_vertex?(graph, node_id) do
      if forward? do
        Graph.reachable(graph, [node_id]) -- [node_id]
      else
        Graph.reaching(graph, [node_id]) -- [node_id]
      end
    else
      []
    end
  end

  defp statements(project, slice_ids, var_name, limit) do
    slice_ids
    |> Enum.map(fn id -> Map.get(project.nodes, id) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.filter(& &1.source_span)
    |> maybe_filter_variable(var_name)
    |> Enum.map(fn node ->
      Statement.new(
        file: node.source_span[:file],
        line: node.source_span[:start_line],
        description: describe_node(node),
        type: node.type
      )
    end)
    |> Enum.sort_by(fn statement -> {statement.file, statement.line} end)
    |> Enum.uniq_by(fn statement -> {statement.file, statement.line} end)
    |> Enum.take(limit)
  end

  defp maybe_filter_variable(nodes, nil), do: nodes

  defp maybe_filter_variable(nodes, var_name) do
    Enum.filter(nodes, fn node ->
      case node.type do
        :var -> to_string(node.meta[:name]) == var_name
        :match -> true
        :call -> true
        _ -> false
      end
    end)
  end

  defp node_specificity(node) do
    case node.type do
      :var -> 0
      :call -> 1
      :literal -> 2
      :match -> 3
      :block -> 10
      :clause -> 11
      :function_def -> 12
      _ -> 5
    end
  end
end
