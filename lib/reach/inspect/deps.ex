defmodule Reach.Inspect.Deps do
  @moduledoc """
  Builds dependency summaries for one target function.
  """

  alias Reach.Project.Query

  def analyze(project, target, depth) do
    %{
      target: target,
      callers: Query.callers(project, target, 1),
      callees: Query.callees(project, target, depth),
      shared_state_writers: find_shared_state(project, target)
    }
  end

  defp find_shared_state(project, target) do
    nodes = project.nodes
    {_mod, fun, arity} = target

    all_func_defs = Map.values(nodes)

    target_calls =
      all_func_defs
      |> Enum.filter(fn n ->
        n.type == :function_def and
          n.meta[:name] == fun and n.meta[:arity] == arity
      end)
      |> Enum.flat_map(&Reach.IR.all_nodes/1)
      |> Enum.filter(fn n -> n.type == :call and Reach.Effects.classify(n) in [:write, :read] end)
      |> Enum.map(& &1.meta[:function])

    all_func_defs
    |> Enum.filter(fn n ->
      n.type == :function_def and {n.meta[:name], n.meta[:arity]} != {fun, arity} and
        n
        |> Reach.IR.all_nodes()
        |> Enum.any?(fn c ->
          c.type == :call and Reach.Effects.classify(c) == :write and
            c.meta[:function] in target_calls
        end)
    end)
    |> Enum.map(&{&1.meta[:module], &1.meta[:name], &1.meta[:arity]})
  end
end
