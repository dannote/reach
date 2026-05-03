defmodule Reach.OTP.Concurrency do
  @moduledoc false

  alias Reach.IR
  alias Reach.IR.Helpers, as: IRHelpers

  def analyze(project) do
    nodes = Map.values(project.nodes)
    graph = project.graph
    edges = Graph.edges(graph)

    %{
      tasks: find_tasks(nodes),
      monitors: find_monitors(nodes),
      spawns: find_spawns(nodes),
      supervisors: find_supervisors(nodes),
      concurrency_edges: classify_concurrency_edges(edges)
    }
  end

  defp find_tasks(nodes) do
    asyncs = Enum.filter(nodes, &task_call?(&1, [:async, :async_stream]))
    awaits = Enum.filter(nodes, &task_call?(&1, [:await, :await_many, :yield, :yield_many]))

    async_locs = Enum.map(asyncs, &IRHelpers.location/1)
    await_locs = Enum.map(awaits, &IRHelpers.location/1)

    unpaired_asyncs = length(asyncs) - length(awaits)

    %{
      async: async_locs,
      await: await_locs,
      unpaired: max(unpaired_asyncs, 0)
    }
  end

  defp find_monitors(nodes) do
    monitors =
      Enum.filter(nodes, fn node ->
        node.type == :call and node.meta[:module] == Process and node.meta[:function] == :monitor
      end)

    trap_exits =
      Enum.filter(nodes, fn node ->
        node.type == :call and node.meta[:module] == Process and node.meta[:function] == :flag and
          match?([%{meta: %{value: :trap_exit}} | _], node.children)
      end)

    down_handlers =
      Enum.filter(nodes, fn node ->
        node.type == :function_def and node.meta[:name] == :handle_info and
          node
          |> IR.all_nodes()
          |> Enum.any?(fn child -> child.type == :literal and child.meta[:value] == :DOWN end)
      end)

    %{
      monitors: Enum.map(monitors, &IRHelpers.location/1),
      trap_exits: Enum.map(trap_exits, &IRHelpers.location/1),
      down_handlers: Enum.map(down_handlers, &func_loc/1)
    }
  end

  defp find_spawns(nodes) do
    spawn_calls =
      Enum.filter(nodes, fn node ->
        node.type == :call and node.meta[:function] in [:spawn, :spawn_link, :spawn_monitor]
      end)

    link_calls =
      Enum.filter(nodes, fn node ->
        node.type == :call and node.meta[:module] == Process and node.meta[:function] == :link
      end)

    %{
      spawns:
        Enum.map(spawn_calls, fn node ->
          %{function: node.meta[:function], location: IRHelpers.location(node)}
        end),
      links: Enum.map(link_calls, &IRHelpers.location/1)
    }
  end

  defp find_supervisors(nodes) do
    init_fns =
      Enum.filter(nodes, fn node ->
        node.type == :function_def and node.meta[:name] == :init and node.meta[:arity] == 1 and
          node
          |> IR.all_nodes()
          |> Enum.any?(fn child ->
            child.type == :call and child.meta[:function] in [:supervise, :init, :child_spec]
          end)
      end)

    start_links =
      Enum.filter(nodes, fn node ->
        node.type == :call and node.meta[:function] == :start_link and
          node.meta[:module] in [Supervisor, DynamicSupervisor]
      end)

    Enum.map(init_fns, &func_loc/1) ++ Enum.map(start_links, &IRHelpers.location/1)
  end

  defp classify_concurrency_edges(edges) do
    edges
    |> Enum.map(& &1.label)
    |> Enum.filter(fn label ->
      label in [
        :monitor_down,
        :trap_exit,
        :link_exit,
        :task_result,
        :startup_order,
        :message_order,
        :state_pass
      ]
    end)
    |> Enum.frequencies()
  end

  defp task_call?(node, functions) do
    node.type == :call and node.meta[:module] == Task and node.meta[:function] in functions
  end

  defp func_loc(node) do
    "#{node.meta[:name]}/#{node.meta[:arity]} at #{IRHelpers.location(node)}"
  end
end
