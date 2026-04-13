defmodule Reach.HigherOrder do
  @moduledoc false

  alias Reach.IR.Node

  # Which params flow to the return value for known higher-order functions.
  # {module, function, arity} => [param_indices_that_flow]
  @catalog %{
    {Enum, :map, 2} => [0, 1],
    {Enum, :flat_map, 2} => [0, 1],
    {Enum, :filter, 2} => [0, 1],
    {Enum, :reject, 2} => [0, 1],
    {Enum, :reduce, 3} => [0, 1, 2],
    {Enum, :scan, 3} => [0, 1, 2],
    {Enum, :sort_by, 2} => [0, 1],
    {Enum, :sort_by, 3} => [0, 1],
    {Enum, :group_by, 2} => [0, 1],
    {Enum, :group_by, 3} => [0, 1],
    {Enum, :map_join, 3} => [0, 2],
    {Enum, :map_reduce, 3} => [0, 1, 2],
    {Enum, :with_index, 1} => [0],
    {Enum, :with_index, 2} => [0],
    {Enum, :zip_with, 2} => [0, 1],
    {Enum, :map_intersperse, 3} => [0, 1],
    {Enum, :map_every, 3} => [0, 2],
    {Enum, :find, 2} => [0],
    {Enum, :find, 3} => [0, 2],
    {Enum, :find_value, 2} => [0, 1],
    {Enum, :count, 2} => [0],
    {Enum, :any?, 2} => [0],
    {Enum, :all?, 2} => [0],
    {Enum, :min_by, 2} => [0],
    {Enum, :max_by, 2} => [0],
    {Enum, :uniq_by, 2} => [0],
    {Enum, :dedup_by, 2} => [0],
    {Stream, :map, 2} => [0, 1],
    {Stream, :filter, 2} => [0, 1],
    {Stream, :flat_map, 2} => [0, 1],
    {Stream, :reject, 2} => [0, 1],
    {Stream, :scan, 3} => [0, 1, 2],
    {Stream, :with_index, 1} => [0],
    {Task, :async, 1} => [0],
    {Task, :await, 1} => [0]
  }

  @doc """
  Adds synthetic data-flow edges for known higher-order function calls.
  """
  @spec add_edges(Graph.t(), [Node.t()]) :: Graph.t()
  def add_edges(graph, all_nodes) do
    all_nodes
    |> Enum.filter(&(&1.type == :call))
    |> Enum.reduce(graph, fn call, g ->
      key = {call.meta[:module], call.meta[:function], call.meta[:arity] || 0}

      case Map.get(@catalog, key) do
        nil -> g
        flowing_params -> add_synthetic_flows(g, call, flowing_params)
      end
    end)
  end

  defp add_synthetic_flows(graph, call_node, flowing_params) do
    args = call_node.children

    Enum.reduce(flowing_params, graph, fn idx, g ->
      case Enum.at(args, idx) do
        nil ->
          g

        arg ->
          g
          |> Graph.add_vertex(arg.id)
          |> Graph.add_vertex(call_node.id)
          |> Graph.add_edge(arg.id, call_node.id, label: :higher_order)
      end
    end)
  end
end
