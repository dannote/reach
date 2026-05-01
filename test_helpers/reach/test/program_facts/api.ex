defmodule Reach.Test.ProgramFacts.API do
  @moduledoc false

  alias Reach.Test.ProgramFacts.{Normalize, Project}

  def analyze(program) do
    Project.with_project(program, fn _dir, project -> project end)
  end

  def modules(program) do
    program
    |> analyze()
    |> Map.fetch!(:modules)
    |> Normalize.modules()
  end

  def call_graph(program), do: analyze(program).call_graph

  def call_edges(program) do
    program
    |> call_graph()
    |> Graph.edges()
    |> Normalize.call_edges()
  end

  def effects(program) do
    program
    |> analyze()
    |> Map.fetch!(:modules)
    |> Enum.flat_map(fn {module, sdg} -> module_effects(module, sdg) end)
    |> MapSet.new()
  end

  defp module_effects(module, sdg) do
    sdg.nodes
    |> Map.values()
    |> Enum.filter(&(&1.type == :function_def))
    |> Enum.flat_map(fn function_node -> function_effects(module, function_node) end)
  end

  defp function_effects(module, function_node) do
    function = {module, function_node.meta[:name], function_node.meta[:arity]}

    effects =
      function_node
      |> flatten_node()
      |> Enum.map(&Reach.Effects.classify/1)
      |> Enum.reject(&(&1 == :pure))
      |> Enum.uniq()

    case effects do
      [] -> [{function, :pure}]
      effects -> Enum.map(effects, &{function, &1})
    end
  end

  defp flatten_node(node), do: [node | Enum.flat_map(node.children, &flatten_node/1)]
end
