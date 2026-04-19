defmodule Mix.Tasks.Reach.Hotspots do
  @moduledoc """
  Functions ranked by complexity × caller count — the highest-risk
  refactoring targets in the codebase.

  A hotspot is a function that is both complex (many branches) and
  heavily called. Changing it is risky; getting it wrong breaks many
  callers.

      mix reach.hotspots
      mix reach.hotspots --format json
      mix reach.hotspots --top 5

  ## Options

    * `--format` — output format: `text` (default), `json`, `oneline`
    * `--top` — show top N hotspots (default: 20)

  """

  use Mix.Task

  alias Reach.CLI.Format
  alias Reach.CLI.Project
  alias Reach.IR
  alias Reach.IR.Helpers

  @shortdoc "Functions ranked by complexity × callers"

  @switches [format: :string, top: :integer]
  @aliases [f: :format]

  @impl Mix.Task
  def run(args) do
    {opts, args, _} = OptionParser.parse(args, switches: @switches, aliases: @aliases)
    format = opts[:format] || "text"
    top = opts[:top] || 20
    path = List.first(args)

    project = Project.load()
    hotspots = analyze(project, top)
    hotspots = Enum.filter(hotspots, &Project.file_matches?(&1.file, path))

    case format do
      "json" ->
        Format.render(%{hotspots: hotspots}, "reach.hotspots", format: "json", pretty: true)

      "oneline" ->
        render_oneline(hotspots)

      _ ->
        render_text(hotspots)
    end
  end

  defp analyze(project, top) do
    nodes = Map.values(project.nodes)
    cg = project.call_graph
    mod_defs = Enum.filter(nodes, &(&1.type == :module_def))

    mod_defs
    |> Enum.flat_map(fn m ->
      mod_name = m.meta[:name]
      funcs = m |> IR.all_nodes() |> Enum.filter(&(&1.type == :function_def))

      Enum.map(funcs, fn f ->
        branches = count_branches(f)
        callers = count_callers(cg, f)

        file = if f.source_span, do: f.source_span.file, else: nil
        line = if f.source_span, do: f.source_span.start_line, else: nil

        %{
          module: inspect(mod_name),
          function: "#{f.meta[:name]}/#{f.meta[:arity]}",
          branches: branches,
          callers: callers,
          score: branches * callers,
          clauses: Helpers.clause_labels(f),
          file: file,
          line: line
        }
      end)
    end)
    |> Enum.filter(&(&1.score > 0))
    |> Enum.sort_by(& &1.score, :desc)
    |> Enum.take(top)
  end

  defp count_branches(func_def) do
    func_def
    |> IR.all_nodes()
    |> Enum.count(&(&1.type == :case))
  end

  defp count_callers(cg, func_def) do
    v = {nil, func_def.meta[:name], func_def.meta[:arity]}

    if Graph.has_vertex?(cg, v) do
      length(Graph.in_neighbors(cg, v))
    else
      0
    end
  end

  # --- Rendering ---

  defp render_text(hotspots) do
    IO.puts(Format.header("Hotspots (#{length(hotspots)})"))

    if hotspots == [] do
      IO.puts("  (no hotspots found)\n")
    else
      Enum.each(hotspots, fn h ->
        IO.puts(
          "  #{Format.bright("#{h.module}.#{h.function}")}  " <>
            "branches=#{h.branches}  callers=#{h.callers}  score=#{score_color(h.score)}"
        )

        if h.file do
          IO.puts("    #{Format.faint("#{h.file}:#{h.line}")}")
        end
      end)

      IO.puts("\n#{Format.count(length(hotspots))} hotspot(s)\n")
    end
  end

  defp render_oneline(hotspots) do
    Enum.each(hotspots, fn h ->
      loc = if h.file && h.line, do: "#{h.file}:#{h.line}", else: ""

      IO.puts(
        "#{h.module}.#{h.function}\tscore=#{h.score}\tbranches=#{h.branches}\tcallers=#{h.callers}\t#{loc}"
      )
    end)
  end

  defp score_color(s), do: Format.threshold_color(s, 10, 20)
end
