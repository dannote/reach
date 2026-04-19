defmodule Mix.Tasks.Reach.Depth do
  @moduledoc """
  Functions ranked by dominator tree depth — the deepest control
  flow nesting in the codebase.

  Dominator depth measures how many levels of control flow must
  be traversed to reach a statement. Functions with deep dominator
  chains have deeply nested branching — `case` inside `case`,
  `if` inside `try` inside `case` — making them hard to reason
  about and test.

      mix reach.depth
      mix reach.depth --format json
      mix reach.depth --top 10
      mix reach.depth --graph

  ## Options

    * `--format` — output format: `text` (default), `json`, `oneline`
    * `--top` — show top N functions (default: 20)
    * `--graph` — render the CFG of the deepest function (requires boxart)

  """

  use Mix.Task

  alias Reach.CLI.BoxartGraph
  alias Reach.CLI.Format
  alias Reach.CLI.Project
  alias Reach.ControlFlow
  alias Reach.Dominator
  alias Reach.IR
  alias Reach.IR.Helpers

  @shortdoc "Functions ranked by dominator tree depth"

  @switches [format: :string, top: :integer, graph: :boolean]
  @aliases [f: :format]

  @impl Mix.Task
  def run(args) do
    {opts, args, _} = OptionParser.parse(args, switches: @switches, aliases: @aliases)
    format = opts[:format] || "text"
    top = opts[:top] || 20
    path = List.first(args)

    project = Project.load()
    result = analyze(project, top)
    result = Enum.filter(result, &Project.file_matches?(&1.file, path))

    if opts[:graph] && result != [] do
      render_graph(project, hd(result))
    else
      case format do
        "json" -> Format.render(%{functions: result}, "reach.depth", format: "json", pretty: true)
        "oneline" -> render_oneline(result)
        _ -> render_text(result)
      end
    end
  end

  defp analyze(project, top) do
    nodes = Map.values(project.nodes)
    mod_defs = Enum.filter(nodes, &(&1.type == :module_def))

    mod_defs
    |> Enum.flat_map(fn m ->
      mod_name = m.meta[:name]
      funcs = m |> IR.all_nodes() |> Enum.filter(&(&1.type == :function_def))

      Enum.flat_map(funcs, fn f ->
        try do
          cfg = ControlFlow.build(f)
          idom = Dominator.idom(cfg, :entry)
          tree = Dominator.tree(idom)
          depth = max_tree_depth(tree, :entry, 0, MapSet.new())

          if depth > 0 do
            file = if f.source_span, do: f.source_span.file, else: nil
            line = if f.source_span, do: f.source_span.start_line, else: nil

            [
              %{
                module: inspect(mod_name),
                function: "#{f.meta[:name]}/#{f.meta[:arity]}",
                depth: depth,
                clauses: Helpers.clause_labels(f),
                file: file,
                line: line
              }
            ]
          else
            []
          end
        rescue
          _ -> []
        end
      end)
    end)
    |> Enum.sort_by(& &1.depth, :desc)
    |> Enum.take(top)
  end

  defp max_tree_depth(tree, node, depth, visited) do
    if MapSet.member?(visited, node) do
      depth
    else
      visited = MapSet.put(visited, node)
      children = Graph.out_neighbors(tree, node)

      if children == [] do
        depth
      else
        children
        |> Enum.map(&max_tree_depth(tree, &1, depth + 1, visited))
        |> Enum.max()
      end
    end
  end

  # --- Rendering ---

  defp render_text(result) do
    IO.puts(Format.header("Dominator Depth (#{length(result)})"))

    if result == [] do
      IO.puts("  (no functions with control flow)\n")
    else
      Enum.each(result, fn f ->
        IO.puts(
          "  #{Format.bright("#{f.module}.#{f.function}")}  " <>
            "depth=#{depth_color(f.depth)}"
        )

        if f.file do
          IO.puts("    #{Format.faint("#{f.file}:#{f.line}")}")
        end
      end)

      IO.puts("\n#{Format.count(length(result))} function(s)\n")
    end
  end

  defp render_oneline(result) do
    Enum.each(result, fn f ->
      loc = if f.file && f.line, do: "#{f.file}:#{f.line}", else: ""
      IO.puts("#{f.module}.#{f.function}\tdepth=#{f.depth}\t#{loc}")
    end)
  end

  defp depth_color(d), do: Format.threshold_color(d, 10, 20)

  defp render_graph(project, top_func) do
    unless BoxartGraph.available?() do
      Mix.raise("boxart is required for --graph. Add {:boxart, \"~> 0.3\"} to your deps.")
    end

    nodes = Map.values(project.nodes)

    func_node =
      Enum.find(nodes, fn f ->
        f.type == :function_def and f.source_span != nil and
          top_func.file != nil and top_func.line != nil and
          f.source_span.file == top_func.file and
          f.source_span.start_line == top_func.line
      end)

    if func_node do
      IO.puts(
        Format.header("CFG: #{top_func.module}.#{top_func.function} (depth=#{top_func.depth})")
      )

      BoxartGraph.render_cfg(func_node, top_func.file)
    else
      IO.puts("  (function node not found for graph rendering)")
    end
  end
end
