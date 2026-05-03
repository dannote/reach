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
  alias Reach.OTP.Concurrency

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
    result = Concurrency.analyze(project)

    case format do
      "json" -> Format.render(result, command(cli_opts), format: "json", pretty: true)
      "oneline" -> render_oneline(result)
      _ -> render_text(result)
    end
  end

  defp command(cli_opts), do: Keyword.get(cli_opts, :command, "reach.otp")

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
