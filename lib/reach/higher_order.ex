defmodule Reach.HigherOrder do
  @moduledoc false

  alias Reach.IR.Node

  @catalog_key :reach_higher_order_catalog

  defp catalog do
    case :persistent_term.get(@catalog_key, nil) do
      nil ->
        result = build_catalog()
        :persistent_term.put(@catalog_key, result)
        result

      result ->
        result
    end
  end

  defp build_catalog do
    for mod <- Reach.Effects.pure_modules(), reduce: %{} do
      acc -> Map.merge(acc, module_flows(mod))
    end
  end

  defp module_flows(mod) do
    for {{^mod, name, arity}, flows} <- Reach.Project.summarize_dependency(mod),
        Reach.Effects.pure_call?(mod, name, arity),
        flowing = for({idx, true} <- flows, do: idx),
        flowing != [],
        into: %{} do
      {{mod, name, arity}, flowing}
    end
  end

  @doc """

  Adds synthetic data-flow edges for known higher-order function calls.

  Only adds edges for pure calls — impure functions (like `Enum.each`)
  use params for side effects, not return value production.
  """
  @spec add_edges(Graph.t(), [Node.t()]) :: Graph.t()
  def add_edges(graph, all_nodes) do
    all_nodes
    |> Enum.filter(&(&1.type == :call))
    |> Enum.reduce(graph, fn call, g -> maybe_add_flow(g, call) end)
  end

  defp maybe_add_flow(graph, call) do
    key = {call.meta[:module], call.meta[:function], call.meta[:arity] || 0}

    case Map.get(catalog(), key) do
      nil -> graph
      flowing -> add_synthetic_flows(graph, call, flowing)
    end
  end

  defp add_synthetic_flows(graph, call_node, flowing_params) do
    args = call_node.children

    Enum.reduce(flowing_params, graph, fn idx, g ->
      case Enum.at(args, idx) do
        nil ->
          g

        arg ->
          Graph.add_edge(
            Graph.add_vertex(Graph.add_vertex(g, arg.id), call_node.id),
            arg.id,
            call_node.id,
            label: :higher_order
          )
      end
    end)
  end
end
