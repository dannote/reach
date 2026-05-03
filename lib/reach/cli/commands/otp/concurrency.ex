defmodule Reach.CLI.Commands.OTP.Concurrency do
  @moduledoc """
  Concurrency patterns — Task.async/await pairing, process monitors,
  spawn_link chains, and supervisor topology.

      mix reach.otp --concurrency
      mix reach.otp --concurrency --format json

  ## Options

    * `--format` — output format: `text` (default), `json`, `oneline`

  """

  alias Reach.CLI.Format
  alias Reach.CLI.Options
  alias Reach.CLI.Project

  @switches [format: :string]
  @aliases [f: :format]

  def run(args, cli_opts \\ []) do
    Options.run(args, @switches, @aliases, fn opts, _positional ->
      run_opts(opts, cli_opts)
    end)
  end

  def run_opts(opts, cli_opts \\ []) do
    format = opts[:format] || "text"

    project = Project.load(quiet: opts[:format] == "json")
    result = analyze(project)

    case format do
      "json" -> Format.render(result, command(cli_opts), format: "json", pretty: true)
      "oneline" -> render_oneline(result)
      _ -> render_text(result)
    end
  end

  defp command(cli_opts), do: Keyword.get(cli_opts, :command, "reach.otp")

  defp analyze(project) do
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

    async_locs = Enum.map(asyncs, &node_loc/1)
    await_locs = Enum.map(awaits, &node_loc/1)

    unpaired_asyncs = length(asyncs) - length(awaits)

    %{
      async: async_locs,
      await: await_locs,
      unpaired: max(unpaired_asyncs, 0)
    }
  end

  defp find_monitors(nodes) do
    monitors =
      Enum.filter(nodes, fn n ->
        n.type == :call and n.meta[:module] == Process and n.meta[:function] == :monitor
      end)

    trap_exits =
      Enum.filter(nodes, fn n ->
        n.type == :call and n.meta[:module] == Process and n.meta[:function] == :flag and
          match?([%{meta: %{value: :trap_exit}} | _], n.children)
      end)

    down_handlers =
      Enum.filter(nodes, fn n ->
        n.type == :function_def and n.meta[:name] == :handle_info and
          n
          |> Reach.IR.all_nodes()
          |> Enum.any?(fn c -> c.type == :literal and c.meta[:value] == :DOWN end)
      end)

    %{
      monitors: Enum.map(monitors, &node_loc/1),
      trap_exits: Enum.map(trap_exits, &node_loc/1),
      down_handlers: Enum.map(down_handlers, &func_loc/1)
    }
  end

  defp find_spawns(nodes) do
    spawn_calls =
      Enum.filter(nodes, fn n ->
        n.type == :call and n.meta[:function] in [:spawn, :spawn_link, :spawn_monitor]
      end)

    link_calls =
      Enum.filter(nodes, fn n ->
        n.type == :call and n.meta[:module] == Process and n.meta[:function] == :link
      end)

    %{
      spawns:
        Enum.map(spawn_calls, fn n ->
          %{function: n.meta[:function], location: node_loc(n)}
        end),
      links: Enum.map(link_calls, &node_loc/1)
    }
  end

  defp find_supervisors(nodes) do
    init_fns =
      Enum.filter(nodes, fn n ->
        n.type == :function_def and n.meta[:name] == :init and n.meta[:arity] == 1 and
          n
          |> Reach.IR.all_nodes()
          |> Enum.any?(fn c ->
            c.type == :call and c.meta[:function] in [:supervise, :init, :child_spec]
          end)
      end)

    start_links =
      Enum.filter(nodes, fn n ->
        n.type == :call and n.meta[:function] == :start_link and
          n.meta[:module] in [Supervisor, DynamicSupervisor]
      end)

    Enum.map(init_fns, &func_loc/1) ++ Enum.map(start_links, &node_loc/1)
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

  defp node_loc(node) do
    case node.source_span do
      %{file: f, start_line: l} -> "#{f}:#{l}"
      _ -> "unknown"
    end
  end

  defp func_loc(node) do
    "#{node.meta[:name]}/#{node.meta[:arity]} at #{node_loc(node)}"
  end

  # --- Rendering ---

  defp render_text(result) do
    IO.puts(Format.header("Concurrency"))

    render_tasks(result.tasks)
    render_monitors(result.monitors)
    render_spawns(result.spawns)
    render_supervisors(result.supervisors)
    render_edges(result.concurrency_edges)
  end

  defp render_tasks(tasks) do
    IO.puts(Format.section("Tasks"))

    if tasks.async == [] and tasks.await == [] and tasks.unpaired == 0 do
      IO.puts("  " <> Format.empty())
    end

    Enum.each(tasks.async, fn loc ->
      IO.puts("  #{Format.green("async")}  #{Format.faint(loc)}")
    end)

    Enum.each(tasks.await, fn loc ->
      IO.puts("  #{Format.cyan("await")}  #{Format.faint(loc)}")
    end)

    if tasks.unpaired > 0 do
      IO.puts("  #{Format.yellow("#{tasks.unpaired} async without matching await")}")
    end
  end

  defp render_monitors(m) do
    IO.puts(Format.section("Monitors"))

    if m.monitors == [] and m.trap_exits == [] and m.down_handlers == [] do
      IO.puts("  " <> Format.empty())
    end

    Enum.each(m.monitors, fn loc ->
      IO.puts("  #{Format.green("Process.monitor")}  #{Format.faint(loc)}")
    end)

    Enum.each(m.trap_exits, fn loc ->
      IO.puts("  #{Format.yellow("trap_exit")}  #{Format.faint(loc)}")
    end)

    Enum.each(m.down_handlers, fn loc ->
      IO.puts("  #{Format.cyan("handle :DOWN")}  #{Format.faint(loc)}")
    end)
  end

  defp render_spawns(s) do
    IO.puts(Format.section("Spawns"))

    if s.spawns == [] and s.links == [] do
      IO.puts("  " <> Format.empty())
    end

    Enum.each(s.spawns, fn %{function: f, location: loc} ->
      IO.puts("  #{Format.yellow(to_string(f))}  #{Format.faint(loc)}")
    end)

    Enum.each(s.links, fn loc ->
      IO.puts("  #{Format.yellow("Process.link")}  #{Format.faint(loc)}")
    end)
  end

  defp render_supervisors(sups) do
    IO.puts(Format.section("Supervisors"))

    if sups == [] do
      IO.puts("  " <> Format.empty())
    end

    Enum.each(sups, fn loc ->
      IO.puts("  #{Format.faint(loc)}")
    end)
  end

  defp render_edges(edges) do
    IO.puts(Format.section("Concurrency Edges"))

    if map_size(edges) == 0 do
      IO.puts("  " <> Format.empty())
    end

    Enum.each(edges, fn {label, count} ->
      IO.puts("  #{Format.bright(to_string(label))}  ×#{count}")
    end)
  end

  defp render_oneline(result) do
    Enum.each(result.tasks.async, &IO.puts("task:async\t#{&1}"))
    Enum.each(result.tasks.await, &IO.puts("task:await\t#{&1}"))
    Enum.each(result.monitors.monitors, &IO.puts("monitor\t#{&1}"))
    Enum.each(result.monitors.trap_exits, &IO.puts("trap_exit\t#{&1}"))
    Enum.each(result.spawns.spawns, fn s -> IO.puts("spawn:#{s.function}\t#{s.location}") end)

    Enum.each(result.concurrency_edges, fn {label, count} ->
      IO.puts("edge:#{label}\t#{count}")
    end)
  end
end
