defmodule Reach.CLI.Commands.Inspect.Deps do
  @moduledoc false

  alias Reach.CLI.BoxartGraph
  alias Reach.CLI.Format
  alias Reach.CLI.Project
  alias Reach.Inspect.Deps, as: DepsAnalysis

  def run_target(raw_target, opts, command \\ "reach.inspect") do
    project = Project.load(quiet: opts[:format] == "json")
    target = Project.resolve_target(project, raw_target)

    unless target do
      Mix.raise("Function not found: #{raw_target}")
    end

    depth = opts[:depth] || 3
    result = DepsAnalysis.analyze(project, target, depth)
    render(result, project, target, depth, opts, command)
  end

  defp render(_result, project, target, depth, %{graph: true}, _command) do
    BoxartGraph.require!()
    BoxartGraph.render_call_graph(project, target, depth)
  end

  defp render(result, _project, _target, _depth, opts, command) do
    case opts[:format] || "text" do
      "json" -> Format.render(result, command, format: "json", pretty: true)
      "oneline" -> render_oneline(result)
      _ -> render_text(result)
    end
  end

  defp render_text(result) do
    target_str = Format.func_id_to_string(result.target)
    IO.puts(Format.header(target_str))

    IO.puts(Format.section("Callers"))

    case result.callers do
      [] ->
        IO.puts("  " <> Format.empty("no callers"))

      callers ->
        Enum.each(callers, fn %{id: id} ->
          IO.puts("  #{Format.func_id_to_string(id)}")
        end)
    end

    IO.puts(Format.section("Callees"))
    render_callee_tree(result.callees, "")

    IO.puts(Format.section("Shared state writers"))

    case result.shared_state_writers do
      [] ->
        IO.puts("  " <> Format.empty())

      writers ->
        Enum.each(writers, &IO.puts("  #{Format.func_id_to_string(&1)}  #{Format.tag(:warning)}"))
    end

    n = length(result.callers)
    risk = if(n > 5, do: "HIGH", else: if(n > 2, do: "MEDIUM", else: "LOW"))
    IO.puts("\n#{n} caller(s), risk: #{risk}\n")
  end

  defp render_callee_tree([], ""), do: IO.puts("  " <> Format.empty())
  defp render_callee_tree([], _prefix), do: nil

  defp render_callee_tree(items, prefix) do
    sorted = Enum.sort_by(items, &Format.func_id_to_string(&1.id))
    count = length(sorted)

    sorted
    |> Enum.with_index()
    |> Enum.each(fn {item, idx} ->
      last? = idx == count - 1
      connector = if last?, do: "└── ", else: "├── "
      child_prefix = if last?, do: "    ", else: "│   "
      IO.puts("#{prefix}#{connector}#{Format.func_id_to_string(item.id)}")
      render_callee_tree(item.children, "#{prefix}#{child_prefix}")
    end)
  end

  defp render_oneline(result) do
    target_str = Format.func_id_to_string(result.target)

    Enum.each(result.callers, fn %{id: id} ->
      IO.puts("#{target_str} ← #{Format.func_id_to_string(id)}")
    end)

    Enum.each(result.shared_state_writers, fn id ->
      IO.puts("#{target_str} shared_state #{Format.func_id_to_string(id)}")
    end)
  end
end
