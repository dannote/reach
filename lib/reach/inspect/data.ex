defmodule Reach.Inspect.Data do
  @moduledoc """
  Builds target-local data-flow summaries for `mix reach.inspect`.
  """

  alias Reach.Analysis
  alias Reach.IR

  def summary(project, func, variable \\ nil) do
    nodes = IR.all_nodes(func)
    node_ids = MapSet.new(nodes, & &1.id)
    nodes_by_id = Map.new(nodes, &{&1.id, &1})

    vars =
      Enum.filter(nodes, fn node ->
        node.type == :var and (variable == nil or to_string(node.meta[:name]) == variable)
      end)

    %{
      definitions:
        vars |> Enum.filter(&(&1.meta[:binding_role] == :definition)) |> Enum.map(&var_summary/1),
      uses:
        vars |> Enum.reject(&(&1.meta[:binding_role] == :definition)) |> Enum.map(&var_summary/1),
      returns: return_summaries(func),
      edges: data_edges(project, node_ids, nodes_by_id, variable)
    }
  end

  defp data_edges(project, node_ids, nodes_by_id, variable) do
    project.graph
    |> Graph.edges()
    |> Enum.filter(fn edge ->
      Analysis.data_edge?(edge) and MapSet.member?(node_ids, edge.v1) and
        MapSet.member?(node_ids, edge.v2) and
        (variable == nil or to_string(data_edge_label(edge)) == variable)
    end)
    |> Enum.take(200)
    |> Enum.map(fn edge ->
      %{
        from: Map.get(nodes_by_id, edge.v1) |> compact_node_summary(),
        to: Map.get(nodes_by_id, edge.v2) |> compact_node_summary(),
        label: inspect(edge.label)
      }
    end)
  end

  defp data_edge_label(%Graph.Edge{label: {:data, var}}), do: var
  defp data_edge_label(%Graph.Edge{label: label}), do: label

  defp return_summaries(func) do
    func.children
    |> List.wrap()
    |> Enum.flat_map(&clause_return/1)
  end

  defp clause_return(%{type: :clause, children: children}) do
    children
    |> List.wrap()
    |> Enum.reverse()
    |> case do
      [] -> []
      [node | _rest] -> [node_summary(node)]
    end
  end

  defp clause_return(node), do: [node_summary(node)]

  defp var_summary(node) do
    span = node.source_span || %{}

    %{
      name: to_string(node.meta[:name]),
      role: to_string(node.meta[:binding_role] || "use"),
      file: span[:file],
      line: span[:start_line]
    }
  end

  defp node_summary(node) do
    span = node.source_span || %{}

    %{
      kind: to_string(node.type),
      file: span[:file],
      line: span[:start_line]
    }
  end

  defp compact_node_summary(nil), do: nil

  defp compact_node_summary(node) do
    span = node.source_span || %{}

    %{
      id: node.id,
      kind: to_string(node.type),
      name: compact_node_name(node),
      file: span[:file],
      line: span[:start_line]
    }
  end

  defp compact_node_name(%{type: :var, meta: meta}), do: meta[:name] && to_string(meta[:name])
  defp compact_node_name(%{type: :call, meta: meta}), do: call_name(meta)
  defp compact_node_name(%{meta: meta}), do: meta[:name] && to_string(meta[:name])

  defp call_name(meta) do
    if meta[:module] do
      "#{inspect(meta[:module])}.#{meta[:function]}/#{meta[:arity]}"
    else
      "#{meta[:function]}/#{meta[:arity]}"
    end
  end
end
