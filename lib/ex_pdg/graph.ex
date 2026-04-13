defmodule ExPDG.Graph do
  @moduledoc """
  Program Dependence Graph.

  Merges control dependence and data dependence into a single graph.
  Provides slicing and independence queries.
  """

  alias ExPDG.{ControlDependence, ControlFlow, DataDependence, Effects, IR}
  alias ExPDG.IR.Node

  @type t :: %__MODULE__{
          graph: Graph.t(),
          ir: [Node.t()],
          control_flow: Graph.t(),
          nodes: %{Node.id() => Node.t()}
        }

  @enforce_keys [:graph, :ir, :control_flow, :nodes]
  defstruct [:graph, :ir, :control_flow, :nodes]

  @doc """
  Builds a PDG from Elixir source code containing a function definition.
  """
  @spec from_string(String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def from_string(source, opts \\ []) do
    case IR.from_string(source, opts) do
      {:ok, nodes} ->
        {:ok, build(nodes)}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Builds a PDG from IR nodes.

  Expects the nodes to contain at least one function definition.
  """
  @spec build([Node.t()]) :: t()
  def build(ir_nodes) do
    func_defs = IR.find_by_type(ir_nodes, :function_def)

    all_nodes = IR.all_nodes(ir_nodes)
    node_map = Map.new(all_nodes, fn n -> {n.id, n} end)

    {flow, control_deps, data_deps} =
      case func_defs do
        [func_def | _] ->
          flow = ControlFlow.build(func_def)
          control_deps = ControlDependence.build(flow)
          data_deps = DataDependence.build(func_def)
          {flow, control_deps, data_deps}

        [] ->
          flow = Graph.new()
          control_deps = Graph.new()
          data_deps = DataDependence.build(ir_nodes)
          {flow, control_deps, data_deps}
      end

    merged = merge_graphs(control_deps, data_deps)

    %__MODULE__{
      graph: merged,
      ir: ir_nodes,
      control_flow: flow,
      nodes: node_map
    }
  end

  @doc """
  Backward slice: all nodes that affect the given node.
  """
  @spec backward_slice(t(), Node.id()) :: [Node.id()]
  def backward_slice(%ExPDG.SystemDependence{graph: graph}, node_id) do
    backward_slice(
      %__MODULE__{graph: graph, ir: [], control_flow: Graph.new(), nodes: %{}},
      node_id
    )
  end

  def backward_slice(%__MODULE__{graph: graph}, node_id) do
    if Graph.has_vertex?(graph, node_id) do
      Graph.reaching(graph, [node_id])
      |> Enum.reject(&(&1 == node_id))
    else
      []
    end
  end

  @doc """
  Forward slice: all nodes affected by the given node.
  """
  @spec forward_slice(t(), Node.id()) :: [Node.id()]
  def forward_slice(%ExPDG.SystemDependence{graph: graph}, node_id) do
    forward_slice(
      %__MODULE__{graph: graph, ir: [], control_flow: Graph.new(), nodes: %{}},
      node_id
    )
  end

  def forward_slice(%__MODULE__{graph: graph}, node_id) do
    if Graph.has_vertex?(graph, node_id) do
      Graph.reachable(graph, [node_id])
      |> Enum.reject(&(&1 == node_id))
    else
      []
    end
  end

  @doc """
  Chop: nodes on paths from `source` to `sink`.

  Returns the intersection of the forward slice of `source`
  and the backward slice of `sink`.
  """
  @spec chop(t(), Node.id(), Node.id()) :: [Node.id()]
  def chop(pdg, source, sink) do
    fwd = forward_slice(pdg, source) |> MapSet.new()
    bwd = backward_slice(pdg, sink) |> MapSet.new()
    MapSet.intersection(fwd, bwd) |> MapSet.to_list()
  end

  @doc """
  Returns the control dependencies of a node.
  """
  @spec control_deps(t(), Node.id()) :: [{Node.id(), term()}]
  def control_deps(%__MODULE__{graph: graph}, node_id) do
    Graph.edges(graph)
    |> Enum.filter(fn e ->
      e.v2 == node_id and match?({:control, _}, e.label)
    end)
    |> Enum.map(fn e -> {e.v1, e.label} end)
  end

  @doc """
  Returns the data dependencies of a node (nodes it depends on).
  """
  @spec data_deps(t(), Node.id()) :: [{Node.id(), atom()}]
  def data_deps(%__MODULE__{graph: graph}, node_id) do
    Graph.edges(graph)
    |> Enum.filter(fn e ->
      e.v2 == node_id and match?({:data, _}, e.label)
    end)
    |> Enum.map(fn e ->
      {:data, var} = e.label
      {e.v1, var}
    end)
  end

  @doc """
  Checks if two nodes are independent.

  Two nodes are independent if:
  1. No data-dependence path between them
  2. They have the same control dependencies
  3. Their effects don't conflict
  """
  @spec independent?(t(), Node.id(), Node.id()) :: boolean()
  def independent?(%__MODULE__{graph: graph, nodes: node_map} = pdg, id_x, id_y) do
    not data_reachable?(graph, id_x, id_y) and
      not data_reachable?(graph, id_y, id_x) and
      same_control_deps?(pdg, id_x, id_y) and
      not conflicting_effects?(node_map, id_x, id_y)
  end

  @doc """
  Returns the IR node for a given ID.
  """
  @spec node(t(), Node.id()) :: Node.t() | nil
  def node(%__MODULE__{nodes: nodes}, id) do
    Map.get(nodes, id)
  end

  @doc """
  Returns all edges in the PDG.
  """
  @spec edges(t()) :: [Graph.Edge.t()]
  def edges(%__MODULE__{graph: graph}) do
    Graph.edges(graph)
  end

  @doc """
  Exports the PDG to DOT format.
  """
  @spec to_dot(t()) :: {:ok, String.t()} | {:error, term()}
  def to_dot(%__MODULE__{graph: graph}) do
    Graph.to_dot(graph)
  end

  # --- Private ---

  defp merge_graphs(control_deps, data_deps) do
    graph =
      Graph.vertices(control_deps)
      |> Enum.reduce(Graph.new(), &Graph.add_vertex(&2, &1))

    graph =
      Graph.edges(control_deps)
      |> Enum.reduce(graph, fn e, g ->
        Graph.add_edge(g, e.v1, e.v2, label: e.label)
      end)

    graph =
      Graph.vertices(data_deps)
      |> Enum.reduce(graph, &Graph.add_vertex(&2, &1))

    Graph.edges(data_deps)
    |> Enum.reduce(graph, fn e, g ->
      Graph.add_edge(g, e.v1, e.v2, label: e.label)
    end)
  end

  defp data_reachable?(graph, from, to) do
    data_only = filter_data_edges(graph)

    if Graph.has_vertex?(data_only, from) and Graph.has_vertex?(data_only, to) do
      Graph.get_shortest_path(data_only, from, to) != nil
    else
      false
    end
  end

  defp filter_data_edges(graph) do
    Enum.reduce(Graph.edges(graph), Graph.new(), fn edge, g ->
      case edge.label do
        {:data, _} ->
          g
          |> Graph.add_vertex(edge.v1)
          |> Graph.add_vertex(edge.v2)
          |> Graph.add_edge(edge.v1, edge.v2, label: edge.label)

        _ ->
          g
      end
    end)
  end

  defp conflicting_effects?(node_map, id_x, id_y) do
    case {Map.get(node_map, id_x), Map.get(node_map, id_y)} do
      {%{} = x, %{} = y} ->
        Effects.conflicting?(Effects.classify(x), Effects.classify(y))

      _ ->
        true
    end
  end

  defp same_control_deps?(pdg, id_x, id_y) do
    deps_x = control_deps(pdg, id_x) |> MapSet.new()
    deps_y = control_deps(pdg, id_y) |> MapSet.new()
    MapSet.equal?(deps_x, deps_y)
  end
end
