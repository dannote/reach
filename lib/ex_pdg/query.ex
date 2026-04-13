defmodule ExPDG.Query do
  @moduledoc """
  Query functions for the program dependence graph.

  Provides composable predicates for filtering nodes and checking
  dependence relationships. These are the runtime building blocks
  that the `ExPDG.Check` macro compiles into.

  ## Examples

      import ExPDG.Query

      # Find all pure call nodes
      nodes(graph, type: :call)
      |> Enum.filter(&pure?/1)

      # Check data flow
      data_flows?(graph, source_id, sink_id)
  """

  alias ExPDG.{Effects, Graph}

  defp unwrap(%Graph{} = g), do: g
  defp unwrap(%ExPDG.SystemDependence{} = sdg), do: wrap_sdg(sdg)

  defp wrap_sdg(sdg) do
    %Graph{
      graph: sdg.graph,
      ir: sdg.ir,
      control_flow: sdg.call_graph,
      nodes: sdg.nodes
    }
  end

  alias ExPDG.IR.Node

  # --- Node queries ---

  @doc """
  Returns all IR nodes from the graph, optionally filtered by criteria.

  ## Options

    * `:type` — filter by node type
    * `:module` — filter calls by module
    * `:function` — filter calls by function name
  """
  @spec nodes(Graph.t() | ExPDG.SystemDependence.t(), keyword()) :: [Node.t()]
  def nodes(graph_or_sdg, opts \\ [])

  def nodes(%Graph{nodes: node_map}, opts) do
    node_map
    |> Map.values()
    |> filter_nodes(opts)
  end

  def nodes(%ExPDG.SystemDependence{} = sdg, opts) do
    nodes(unwrap(sdg), opts)
  end

  @doc """
  Returns true if there's a data-dependence path from `source` to `sink`.
  """
  @spec data_flows?(Graph.t(), Node.id(), Node.id()) :: boolean()
  def data_flows?(graph, source_id, sink_id) do
    graph = unwrap(graph)
    sink_id in Graph.forward_slice(graph, source_id)
  end

  @doc """
  Returns true if `controller` has a control-dependence path to `target`.
  """
  @spec controls?(Graph.t(), Node.id(), Node.id()) :: boolean()
  def controls?(graph, controller_id, target_id) do
    graph = unwrap(graph)

    Graph.control_deps(graph, target_id)
    |> Enum.any?(fn {id, _label} -> id == controller_id end)
  end

  @doc """
  Returns true if there's any dependence path between two nodes.
  """
  @spec depends?(Graph.t(), Node.id(), Node.id()) :: boolean()
  def depends?(graph, id_a, id_b) do
    graph = unwrap(graph)

    id_b in Graph.forward_slice(graph, id_a) or
      id_a in Graph.forward_slice(graph, id_b)
  end

  @doc """
  Returns true if `node_id` has data dependents (other nodes use its value).
  """
  @spec has_dependents?(Graph.t(), Node.id()) :: boolean()
  def has_dependents?(graph, node_id) do
    graph = unwrap(graph)
    Graph.forward_slice(graph, node_id) != []
  end

  @doc """
  Returns true if the data-flow path from `source` to `sink` passes
  through any node matching `predicate`.
  """
  @spec passes_through?(Graph.t(), Node.id(), Node.id(), (Node.t() -> boolean())) :: boolean()
  def passes_through?(graph, source_id, sink_id, predicate) do
    graph = unwrap(graph)
    path_nodes = Graph.chop(graph, source_id, sink_id)

    Enum.any?(path_nodes, fn id ->
      case Graph.node(graph, id) do
        nil -> false
        node -> predicate.(node)
      end
    end)
  end

  @doc """
  Returns true if the node's result is the return value of its function.
  """
  @spec returns?(Graph.t(), Node.id()) :: boolean()
  def returns?(graph, node_id) do
    %Graph{control_flow: control_flow} = unwrap(graph)

    if Elixir.Graph.has_vertex?(control_flow, node_id) do
      control_flow
      |> Elixir.Graph.out_neighbors(node_id)
      |> Enum.any?(&(&1 == :exit))
    else
      false
    end
  end

  # --- Effect predicates (delegate to Effects module) ---

  @doc "Returns true if the node is pure."
  @spec pure?(Node.t()) :: boolean()
  defdelegate pure?(node), to: Effects

  @doc "Returns true if the node has the given effect."
  @spec effectful?(Node.t(), Effects.effect()) :: boolean()
  defdelegate effectful?(node, effect), to: Effects

  # --- Helpers ---

  defp filter_nodes(nodes, []), do: nodes

  defp filter_nodes(nodes, [{:type, type} | rest]) do
    nodes |> Enum.filter(&(&1.type == type)) |> filter_nodes(rest)
  end

  defp filter_nodes(nodes, [{:module, module} | rest]) do
    nodes |> Enum.filter(&(&1.meta[:module] == module)) |> filter_nodes(rest)
  end

  defp filter_nodes(nodes, [{:function, function} | rest]) do
    nodes |> Enum.filter(&(&1.meta[:function] == function)) |> filter_nodes(rest)
  end

  defp filter_nodes(nodes, [_ | rest]) do
    filter_nodes(nodes, rest)
  end
end
