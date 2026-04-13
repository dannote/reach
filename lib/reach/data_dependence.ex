defmodule Reach.DataDependence do
  @moduledoc false

  alias Reach.IR.Node

  @doc """
  Builds a data dependence graph from IR nodes.

  Returns a `Graph.t()` where edges represent data flow from definitions to uses.
  """
  @spec build([Node.t()] | Node.t()) :: Graph.t()
  def build(nodes) do
    nodes = List.wrap(nodes)
    all = Reach.IR.all_nodes(nodes)

    # Collect definitions and uses for each node
    bindings = Enum.map(all, fn node -> {node.id, analyze_bindings(node)} end) |> Map.new()

    # Build def-use edges by scope-aware reaching definitions
    build_def_use_graph(all, bindings)
  end

  @doc """
  Analyzes which variables a node defines and uses.

  Returns `{definitions, uses}` where each is a list of variable names.
  """
  @spec analyze_bindings(Node.t()) :: {[atom()], [atom()]}
  def analyze_bindings(%Node{type: :var, meta: %{name: name}}) do
    {[], [name]}
  end

  def analyze_bindings(%Node{type: :match, children: [left, _right]}) do
    defs = collect_definitions(left)
    {defs, []}
  end

  def analyze_bindings(%Node{type: :clause, meta: %{kind: kind}} = node)
      when kind in [:function_clause, :fn_clause] do
    params = node.children |> Enum.reject(&(&1.type in [:guard, :block]))
    defs = Enum.flat_map(params, &collect_definitions/1)
    {defs, []}
  end

  def analyze_bindings(%Node{type: :clause, meta: %{kind: kind}} = node)
      when kind in [:case_clause, :receive_clause, :with_clause, :else_clause] do
    # First children are patterns
    patterns =
      node.children
      |> Enum.take_while(&(&1.type not in [:guard, :block, :call, :binary_op, :literal]))

    defs = Enum.flat_map(patterns, &collect_definitions/1)
    {defs, []}
  end

  def analyze_bindings(%Node{type: :generator, children: [pattern, _enumerable]}) do
    defs = collect_definitions(pattern)
    {defs, []}
  end

  def analyze_bindings(%Node{type: :pin, children: [%Node{type: :var, meta: %{name: name}}]}) do
    {[], [name]}
  end

  def analyze_bindings(_node) do
    {[], []}
  end

  @doc """
  Collects variable names defined by a pattern.
  """
  @spec collect_definitions(Node.t()) :: [atom()]
  def collect_definitions(%Node{type: :var, meta: %{name: name}}) do
    [name]
  end

  def collect_definitions(%Node{type: :pin}) do
    []
  end

  def collect_definitions(%Node{type: type, children: children})
      when type in [:tuple, :list, :cons, :map, :map_field, :struct, :match, :binary_op] do
    Enum.flat_map(children, &collect_definitions/1)
  end

  def collect_definitions(_node) do
    []
  end

  # --- Private ---

  defp build_def_use_graph(all_nodes, bindings) do
    def_map = build_def_map(all_nodes, bindings)

    graph =
      Enum.reduce(all_nodes, Graph.new(), fn node, graph ->
        {_defs, uses} = Map.get(bindings, node.id, {[], []})

        Enum.reduce(uses, graph, fn var_name, g ->
          def_map
          |> Map.get(var_name, [])
          |> Enum.reject(&(&1 == node.id))
          |> Enum.reduce(g, &add_data_edge(&2, &1, node.id, var_name))
        end)
      end)

    add_containment_edges(graph, all_nodes)
  end

  defp add_containment_edges(graph, all_nodes) do
    all_nodes
    |> Enum.filter(&value_depends_on_children?/1)
    |> Enum.reduce(graph, &add_child_edges/2)
  end

  defp add_child_edges(node, graph) do
    Enum.reduce(node.children, graph, fn child, g ->
      g
      |> Graph.add_vertex(child.id)
      |> Graph.add_vertex(node.id)
      |> Graph.add_edge(child.id, node.id, label: :containment)
    end)
  end

  @value_types [
    :binary_op,
    :unary_op,
    :call,
    :tuple,
    :list,
    :cons,
    :map,
    :map_field,
    :struct,
    :match,
    :comprehension
  ]

  defp value_depends_on_children?(%Node{type: type}) when type in @value_types, do: true
  defp value_depends_on_children?(_), do: false

  defp build_def_map(all_nodes, bindings) do
    Enum.reduce(all_nodes, %{}, fn node, acc ->
      {defs, _uses} = Map.get(bindings, node.id, {[], []})

      Enum.reduce(defs, acc, fn var_name, inner_acc ->
        Map.update(inner_acc, var_name, [node.id], &[node.id | &1])
      end)
    end)
  end

  defp add_data_edge(graph, def_id, use_id, var_name) do
    graph
    |> Graph.add_vertex(def_id)
    |> Graph.add_vertex(use_id)
    |> Graph.add_edge(def_id, use_id, label: {:data, var_name})
  end
end
