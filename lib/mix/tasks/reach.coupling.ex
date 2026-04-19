defmodule Mix.Tasks.Reach.Coupling do
  @moduledoc """
  Module-level coupling metrics — afferent, efferent, instability,
  and circular dependency chains.

  Inspired by Martin's instability metric: I = Ce / (Ca + Ce).
  Stable modules (I ≈ 0) are depended upon but depend on little.
  Unstable modules (I ≈ 1) depend on many but nothing depends on them.

      mix reach.coupling
      mix reach.coupling --format json
      mix reach.coupling --sort afferent

  ## Options

    * `--format` — output format: `text` (default), `json`, `oneline`
    * `--sort` — sort by: `instability` (default), `afferent`, `efferent`,
      `name`

  """

  use Mix.Task

  alias Reach.CLI.BoxartGraph
  alias Reach.CLI.Format
  alias Reach.CLI.Project
  alias Reach.IR

  @shortdoc "Module coupling metrics (afferent, efferent, circular deps)"

  @switches [format: :string, sort: :string, graph: :boolean]
  @aliases [f: :format]

  @impl Mix.Task
  def run(args) do
    {opts, _args, _} = OptionParser.parse(args, switches: @switches, aliases: @aliases)
    format = opts[:format] || "text"
    sort = opts[:sort] || "instability"

    project = Project.load()
    result = analyze(project, sort)

    if opts[:graph] do
      render_graph(project)
    else
      case format do
        "json" -> Format.render(result, "reach.coupling", format: "json", pretty: true)
        "oneline" -> render_oneline(result)
        _ -> render_text(result)
      end
    end
  end

  defp analyze(project, sort) do
    nodes = Map.values(project.nodes)
    mod_defs = Enum.filter(nodes, &(&1.type == :module_def))
    internal = MapSet.new(mod_defs, & &1.meta[:name])

    efferent_map = build_efferent_map(mod_defs, internal)
    afferent_map = invert_efferent(efferent_map)

    modules =
      build_module_metrics(mod_defs, efferent_map, afferent_map)
      |> sort_modules(sort)

    cycles = find_cycles(efferent_map, 5)

    %{modules: modules, circular_dependencies: cycles}
  end

  defp build_efferent_map(mod_defs, internal) do
    Map.new(mod_defs, fn m ->
      deps =
        m
        |> IR.all_nodes()
        |> Enum.filter(
          &(&1.type == :call and &1.meta[:kind] == :remote and &1.meta[:module] != nil)
        )
        |> Enum.map(& &1.meta[:module])
        |> Enum.filter(&MapSet.member?(internal, &1))
        |> Enum.uniq()

      {m.meta[:name], deps}
    end)
  end

  defp invert_efferent(efferent_map) do
    Enum.reduce(efferent_map, %{}, fn {mod, deps}, acc ->
      Enum.reduce(deps, acc, fn dep, a ->
        Map.update(a, dep, MapSet.new([mod]), &MapSet.put(&1, mod))
      end)
    end)
    |> Map.new(fn {k, v} -> {k, MapSet.to_list(v)} end)
  end

  defp build_module_metrics(mod_defs, efferent_map, afferent_map) do
    mod_defs
    |> Enum.map(fn m ->
      mod_name = m.meta[:name]
      file = if m.source_span, do: m.source_span.file, else: nil
      func_count = m |> IR.all_nodes() |> Enum.count(&(&1.type == :function_def))

      ce = length(Map.get(efferent_map, mod_name, []))
      ca = length(Map.get(afferent_map, mod_name, []))
      total = ca + ce
      instability = if total > 0, do: Float.round(ce / total, 2), else: 0.0

      %{
        name: inspect(mod_name),
        file: file,
        functions: func_count,
        afferent: ca,
        efferent: ce,
        instability: instability
      }
    end)
    |> Enum.reject(&(&1.functions == 0))
  end

  defp sort_modules(modules, "afferent"), do: Enum.sort_by(modules, & &1.afferent, :desc)
  defp sort_modules(modules, "efferent"), do: Enum.sort_by(modules, & &1.efferent, :desc)
  defp sort_modules(modules, "instability"), do: Enum.sort_by(modules, & &1.instability, :desc)
  defp sort_modules(modules, _), do: Enum.sort_by(modules, & &1.name)

  defp find_cycles(efferent_map, max_len) do
    efferent_map
    |> Map.keys()
    |> Enum.flat_map(&walk_cycle(efferent_map, &1, &1, [], max_len))
    |> Enum.map(&Enum.sort/1)
    |> Enum.uniq()
    |> Enum.map(fn cycle -> %{modules: Enum.map(cycle, &inspect/1)} end)
  end

  defp walk_cycle(_graph, _start, _current, path, max) when length(path) >= max, do: []

  defp walk_cycle(graph, start, current, path, max) do
    neighbors = Map.get(graph, current, [])

    Enum.flat_map(neighbors, fn neighbor ->
      cond do
        neighbor == start and path != [] ->
          [Enum.reverse([current | path])]

        neighbor in path ->
          []

        true ->
          walk_cycle(graph, start, neighbor, [current | path], max)
      end
    end)
  end

  # --- Rendering ---

  defp render_text(result) do
    IO.puts(Format.header("Module Coupling (#{length(result.modules)})"))

    Enum.each(result.modules, fn m ->
      IO.puts("  #{Format.bright(m.name)}")
      IO.puts("    Ca=#{m.afferent}, Ce=#{m.efferent}, instability #{inst_color(m.instability)}")

      if m.file do
        IO.puts("    #{Format.faint(m.file)}")
      end

      IO.puts("")
    end)

    total = length(result.modules)
    total_ca = result.modules |> Enum.map(& &1.afferent) |> Enum.sum()
    total_ce = result.modules |> Enum.map(& &1.efferent) |> Enum.sum()
    IO.puts("#{total} modules, #{total_ca} afferent + #{total_ce} efferent couplings")

    render_cycles(result.circular_dependencies)
  end

  defp render_cycles([]), do: :ok

  defp render_cycles(cycles) do
    IO.puts(Format.section("Circular Dependencies"))

    Enum.each(cycles, fn %{modules: mods} ->
      IO.puts("  #{Format.red(Enum.join(mods, " → "))} → #{Format.red(hd(mods))}")
    end)

    IO.puts("\n#{Format.count(length(cycles))} cycle(s)\n")
  end

  defp render_oneline(result) do
    Enum.each(result.modules, fn m ->
      IO.puts("#{m.name}\tCa=#{m.afferent}\tCe=#{m.efferent}\tI=#{m.instability}")
    end)

    Enum.each(result.circular_dependencies, fn %{modules: mods} ->
      IO.puts("cycle:\t#{Enum.join(mods, " → ")}")
    end)
  end

  defp inst_color(i) when i > 0.8, do: Format.red(to_string(i))
  defp inst_color(i) when i > 0.5, do: Format.yellow(to_string(i))
  defp inst_color(i), do: Format.green(to_string(i))

  defp render_graph(project) do
    unless BoxartGraph.available?() do
      Mix.raise("boxart is required for --graph. Add {:boxart, \"~> 0.3\"} to your deps.")
    end

    BoxartGraph.render_module_graph(project)
  end
end
