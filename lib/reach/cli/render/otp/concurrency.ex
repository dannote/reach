defmodule Reach.CLI.Render.OTP.Concurrency do
  @moduledoc false

  alias Reach.CLI.Format

  def render(result, format, command) do
    case format do
      "json" -> Format.render(result, command, format: "json", pretty: true)
      "oneline" -> render_oneline(result)
      _ -> render_text(result)
    end
  end

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

  defp render_monitors(monitors) do
    IO.puts(Format.section("Monitors"))

    if monitors.monitors == [] and monitors.trap_exits == [] and monitors.down_handlers == [] do
      IO.puts("  " <> Format.empty())
    end

    Enum.each(monitors.monitors, fn loc ->
      IO.puts("  #{Format.green("Process.monitor")}  #{Format.faint(loc)}")
    end)

    Enum.each(monitors.trap_exits, fn loc ->
      IO.puts("  #{Format.yellow("trap_exit")}  #{Format.faint(loc)}")
    end)

    Enum.each(monitors.down_handlers, fn loc ->
      IO.puts("  #{Format.cyan("handle :DOWN")}  #{Format.faint(loc)}")
    end)
  end

  defp render_spawns(spawns) do
    IO.puts(Format.section("Spawns"))

    if spawns.spawns == [] and spawns.links == [] do
      IO.puts("  " <> Format.empty())
    end

    Enum.each(spawns.spawns, fn %{function: function, location: loc} ->
      IO.puts("  #{Format.yellow(to_string(function))}  #{Format.faint(loc)}")
    end)

    Enum.each(spawns.links, fn loc ->
      IO.puts("  #{Format.yellow("Process.link")}  #{Format.faint(loc)}")
    end)
  end

  defp render_supervisors(supervisors) do
    IO.puts(Format.section("Supervisors"))

    if supervisors == [] do
      IO.puts("  " <> Format.empty())
    end

    Enum.each(supervisors, fn loc ->
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

    Enum.each(result.spawns.spawns, fn spawn ->
      IO.puts("spawn:#{spawn.function}\t#{spawn.location}")
    end)

    Enum.each(result.concurrency_edges, fn {label, count} ->
      IO.puts("edge:#{label}\t#{count}")
    end)
  end
end
