defmodule Mix.Tasks.Reach.Map do
  @moduledoc """
  Shows a project-level map of modules, coupling, hotspots, depth, effects,
  boundaries, and data-flow summaries.

      mix reach.map
      mix reach.map --modules
      mix reach.map --coupling
      mix reach.map --hotspots
      mix reach.map --effects
      mix reach.map --boundaries
      mix reach.map --depth
      mix reach.map --data
      mix reach.map --format json

  ## Options

    * `--format` — output format: `text`, `json`, `oneline`
    * `--modules` — show module inventory
    * `--coupling` — show module coupling and cycles
    * `--hotspots` — show risky high-impact functions
    * `--effects` — show effect distribution
    * `--boundaries` — show mixed-effect functions
    * `--depth` — show functions ranked by dominator depth
    * `--data` — show cross-function data-flow summary
    * `--top` — pass top-N limit to analyses that support it
    * `--sort` — sort modules/coupling sections (`name`, `functions`, `complexity`, `afferent`, `efferent`, `instability`)
    * `--module` — restrict effects to a module name fragment
    * `--min` — minimum distinct effects for `--boundaries` (default: 2)
    * `--orphans` — with `--coupling`, show only orphan modules
    * `--graph` — render a terminal graph for graph-capable sections

  """

  use Mix.Task

  @compile {:no_warn_undefined, [Boxart.Render.PieChart, Boxart.Render.PieChart.PieChart]}
  @dialyzer {:nowarn_function, render_depth_row_graph: 2}

  alias Reach.CLI.BoxartGraph
  alias Reach.CLI.Format
  alias Reach.CLI.Project
  alias Reach.Map.Analysis, as: MapAnalysis

  @shortdoc "Project structure and risk map"

  @switches [
    format: :string,
    modules: :boolean,
    coupling: :boolean,
    hotspots: :boolean,
    effects: :boolean,
    boundaries: :boolean,
    depth: :boolean,
    data: :boolean,
    xref: :boolean,
    top: :integer,
    sort: :string,
    module: :string,
    min: :integer,
    orphans: :boolean,
    graph: :boolean
  ]

  @aliases [f: :format]
  @section_order [:hotspots, :boundaries, :coupling, :modules, :effects, :depth, :data, :xref]

  @impl Mix.Task
  def run(args) do
    {opts, positional, _} = OptionParser.parse(args, switches: @switches, aliases: @aliases)
    render_map(opts, positional)
  end

  defp render_map(opts, path_args) do
    project = Project.load(quiet: opts[:format] == "json")
    path = List.first(path_args)
    sections = selected_keys(opts)

    sections =
      if sections == [], do: [:hotspots, :boundaries, :coupling, :modules], else: sections

    if opts[:graph] do
      render_graph(project, sections, opts, path)
    else
      result = %{
        command: "reach.map",
        summary: summary(project, path),
        sections: Map.new(sections, &{&1, section_data(project, &1, opts, path)})
      }

      case opts[:format] do
        "json" ->
          ensure_json_encoder!()
          IO.puts(Jason.encode!(json_envelope(result), pretty: true))

        "oneline" ->
          render_oneline_map(result)

        _ ->
          render_text_map(result)
      end
    end
  end

  defp render_text_map(%{summary: summary, sections: sections}) do
    if map_size(sections) == 1 do
      [{key, data}] = Map.to_list(sections)
      IO.puts(Format.header(section_header(key, data)))
      render_text_section(key, data)
    else
      IO.puts(Format.header("Reach Map"))
      IO.puts("  modules=#{summary.modules} functions=#{summary.functions}")

      IO.puts(
        "  call_graph=#{summary.call_graph_vertices} vertices/#{summary.call_graph_edges} edges"
      )

      IO.puts("  pdg=#{summary.graph_nodes} nodes/#{summary.graph_edges} edges")

      Enum.each(ordered_sections(sections), fn {key, data} ->
        IO.puts(Format.section(section_title(key)))
        render_text_section(key, data)
      end)
    end
  end

  defp render_oneline_map(%{summary: summary, sections: sections}) do
    IO.puts(
      "summary modules=#{summary.modules} functions=#{summary.functions} call_edges=#{summary.call_graph_edges} graph_edges=#{summary.graph_edges}"
    )

    Enum.each(ordered_sections(sections), fn
      {:modules, modules} ->
        Enum.each(
          modules,
          &IO.puts(
            "module #{&1.name} functions=#{&1.total_functions} complexity=#{&1.total_complexity}"
          )
        )

      {:hotspots, hotspots} ->
        Enum.each(
          hotspots,
          &IO.puts(
            "hotspot #{&1.function} score=#{&1.score} branches=#{&1.branches} callers=#{&1.callers}"
          )
        )

      {:boundaries, boundaries} ->
        Enum.each(
          boundaries,
          &IO.puts("boundary #{&1.function} effects=#{Enum.join(&1.effects, "+")}")
        )

      {:effects, %{distribution: distribution}} ->
        Enum.each(distribution, fn row -> IO.puts("effect #{row.effect}=#{row.count}") end)

      {:effects, effects} ->
        Enum.each(effects, fn {effect, count} -> IO.puts("effect #{effect}=#{count}") end)

      {:data, data} ->
        Enum.each(data.top_functions, &IO.puts("data #{&1.function} edges=#{&1.data_edges}"))

        Enum.each(
          data.cross_function_edges || [],
          &IO.puts("xref #{&1.from} -> #{&1.to} edges=#{&1.edges}")
        )

      {:coupling, data} ->
        Enum.each(
          data.modules,
          &IO.puts("coupling #{&1.name} ca=#{&1.afferent} ce=#{&1.efferent} i=#{&1.instability}")
        )

      {:depth, rows} ->
        Enum.each(
          rows,
          &IO.puts("depth #{&1.function} depth=#{&1.depth} branches=#{&1.branch_count}")
        )
    end)
  end

  defp render_text_section(:modules, modules) do
    Enum.each(modules, fn module ->
      behaviours = module_behaviour_label(module.callbacks)
      IO.puts("  #{Format.bright(module.name)}#{Format.cyan(behaviours)}")

      IO.puts(
        "    #{module.public_count} public, #{module.private_count} private, complexity #{module.total_complexity}"
      )

      if module.biggest_function,
        do: IO.puts("    biggest: #{Format.yellow(module.biggest_function)}")

      if module.file, do: IO.puts("    #{Format.faint(module.file)}")
      IO.puts("")
    end)
  end

  defp render_text_section(:hotspots, hotspots) do
    Enum.each(hotspots, fn hotspot ->
      label = Map.get(hotspot, :display_function, hotspot.function)

      IO.puts(
        "  #{Format.bright(label)} score=#{hotspot.score} branches=#{hotspot.branches} callers=#{hotspot.callers}"
      )

      IO.puts("    #{Format.faint("#{hotspot.file}:#{hotspot.line}")}")
    end)
  end

  defp render_text_section(:coupling, %{modules: modules, cycles: cycles}) do
    Enum.each(modules, fn module ->
      IO.puts(
        "  #{Format.bright(module.name)} Ca=#{module.afferent} Ce=#{module.efferent} I=#{module.instability}"
      )
    end)

    if cycles != [] do
      IO.puts("  cycles:")
      Enum.each(cycles, &IO.puts("    #{Enum.join(&1.modules, " -> ")}"))
    end
  end

  defp render_text_section(:effects, %{distribution: distribution, unknown_calls: unknown_calls}) do
    Enum.each(distribution, fn row -> IO.puts("  #{row.effect}: #{row.count} (#{row.ratio})") end)

    if unknown_calls != [] do
      IO.puts("  unknown calls:")
      Enum.each(unknown_calls, &IO.puts("    #{&1.module}.#{&1.function}: #{&1.count}"))
    end
  end

  defp render_text_section(:effects, effects) do
    Enum.each(effects, fn {effect, count} -> IO.puts("  #{effect}: #{count}") end)
  end

  defp render_text_section(:boundaries, boundaries) do
    Enum.each(boundaries, fn boundary ->
      IO.puts(
        "  #{Format.bright(boundary.display_function)} effects=#{Enum.join(boundary.effects, "+")}"
      )

      Enum.each(boundary.calls, fn call ->
        IO.puts("    #{call.effect} #{call.call}")
      end)

      IO.puts("    #{Format.faint("#{boundary.file}:#{boundary.line}")}")
    end)
  end

  defp render_text_section(:depth, rows) do
    Enum.each(rows, fn row ->
      IO.puts("  #{Format.bright(row.function)} depth=#{row.depth} branches=#{row.branch_count}")
      IO.puts("    #{Format.faint("#{row.file}:#{row.line}")}")
    end)
  end

  defp render_text_section(:data, data) do
    IO.puts("  total_data_edges=#{data.total_data_edges}")
    render_cross_function_flows(Map.get(data, :cross_function_edges, []))
    render_top_data_functions(data.top_functions)
  end

  defp render_cross_function_flows([]), do: :ok

  defp render_cross_function_flows(edges) do
    IO.puts("\n  Cross-function flows:")
    Enum.each(edges, &render_cross_function_flow/1)
  end

  defp render_cross_function_flow(row) do
    labels = row.labels |> Enum.map_join(", ", fn {label, count} -> "#{label}=#{count}" end)
    variables = Enum.join(row.variables, ", ")
    IO.puts("    #{Format.bright(row.from)} → #{Format.bright(row.to)} edges=#{row.edges}")
    IO.puts("      labels: #{labels}")
    if variables != "", do: IO.puts("      vars: #{variables}")
  end

  defp render_top_data_functions(rows) do
    IO.puts("\n  Functions by data edges:")

    Enum.each(rows, fn row ->
      IO.puts("    #{Format.bright(row.function)} data_edges=#{row.data_edges}")
      IO.puts("      #{Format.faint("#{row.file}:#{row.line}")}")
    end)
  end

  defp ordered_sections(sections) do
    Enum.sort_by(sections, fn {key, _data} ->
      Enum.find_index(@section_order, &(&1 == key)) || 999
    end)
  end

  defp section_title(:modules), do: "Modules"
  defp section_title(:hotspots), do: "Hotspots"
  defp section_title(:coupling), do: "Coupling"
  defp section_title(:effects), do: "Effects"
  defp section_title(:boundaries), do: "Effect Boundaries"
  defp section_title(:depth), do: "Control Depth"
  defp section_title(:data), do: "Data Flow"

  defp section_header(:modules, data), do: "Modules (#{length(data)})"
  defp section_header(:hotspots, data), do: "Hotspots (#{length(data)})"
  defp section_header(:coupling, data), do: "Module Coupling (#{length(data.modules)})"
  defp section_header(:effects, data), do: "Effect Distribution (#{data.total_calls} calls)"
  defp section_header(:boundaries, data), do: "Effect Boundaries (#{length(data)})"
  defp section_header(:depth, data), do: "Dominator Depth (#{length(data)})"
  defp section_header(:data, data), do: "Data Flow (#{length(data.top_functions)})"

  defp selected_keys(opts) do
    [:modules, :coupling, :hotspots, :effects, :boundaries, :depth, :data, :xref]
    |> Enum.filter(&opts[&1])
    |> Enum.map(fn
      :xref -> :data
      key -> key
    end)
    |> Enum.uniq()
  end

  defp summary(project, path), do: MapAnalysis.summary(project, path)

  defp section_data(project, section, opts, path),
    do: MapAnalysis.section_data(project, section, opts, path)

  defp render_graph(project, sections, opts, path) do
    ensure_boxart!()

    cond do
      :coupling in sections or :modules in sections ->
        BoxartGraph.render_module_graph(project)

      :effects in sections ->
        render_effect_graph(section_data(project, :effects, opts, path))

      :depth in sections ->
        render_depth_graph(project, opts, path)

      true ->
        Mix.raise(
          "--graph is supported with --modules, --coupling, or --depth. For target graphs, use mix reach.inspect TARGET --graph"
        )
    end
  end

  defp render_depth_graph(project, opts, path) do
    case section_data(project, :depth, opts, path) do
      [row | _] -> render_depth_row_graph(project, row)
      [] -> IO.puts("  (no functions found)")
    end
  end

  defp render_depth_row_graph(project, row) do
    func = Project.find_function_at_location(project, row.file, row.line)

    if func do
      BoxartGraph.render_cfg(func, row.file)
      :ok
    else
      Mix.raise("Function not found: #{row.function}")
    end
  end

  defp module_behaviour_label([]), do: ""
  defp module_behaviour_label([behaviour | _]) when is_binary(behaviour), do: " (#{behaviour})"
  defp module_behaviour_label(_callbacks), do: ""

  defp render_effect_graph(result) do
    BoxartGraph.require_pie_chart!()
    chart_module = Module.concat([Boxart, Render, PieChart, PieChart])

    slices =
      result.distribution
      |> Enum.reject(&(&1.count == 0))
      |> Enum.map(&{&1.effect, &1.ratio * 100})

    chart =
      struct!(chart_module,
        title: "Effect Distribution (#{result.total_calls} calls)",
        slices: slices,
        show_data: true
      )

    IO.puts(Boxart.Render.PieChart.render(chart))
  end

  defp json_envelope(%{command: command} = data) do
    %Reach.CLI.JSONEnvelope{command: command, data: Map.delete(data, :command)}
  end

  defp ensure_json_encoder! do
    unless Code.ensure_loaded?(Jason) do
      Mix.raise("Jason is required for JSON output. Add {:jason, \"~> 1.0\"} to your deps.")
    end
  end

  defp ensure_boxart!, do: BoxartGraph.require!()
end
