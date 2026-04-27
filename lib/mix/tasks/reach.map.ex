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

  """

  use Mix.Task

  alias Reach.CLI.Analysis
  alias Reach.CLI.Format
  alias Reach.CLI.Project
  alias Reach.Effects
  alias Reach.IR

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
    sort: :string
  ]

  @aliases [f: :format]

  @impl Mix.Task
  def run(args) do
    {opts, positional, _} = OptionParser.parse(args, switches: @switches, aliases: @aliases)
    render_map(opts, positional)
  end

  defp render_map(opts, path_args) do
    project = Project.load()
    path = List.first(path_args)
    sections = selected_keys(opts)

    sections =
      if sections == [], do: [:modules, :hotspots, :coupling, :boundaries], else: sections

    result = %{
      command: "reach.map",
      summary: summary(project, path),
      sections: Map.new(sections, &{&1, section_data(project, &1, opts, path)})
    }

    case opts[:format] do
      "json" ->
        ensure_json_encoder!()
        IO.puts(Jason.encode!(result, pretty: true))

      "oneline" ->
        render_oneline_map(result)

      _ ->
        render_text_map(result)
    end
  end

  defp render_text_map(%{summary: summary, sections: sections}) do
    IO.puts(Format.header("Reach Map"))
    IO.puts("  modules=#{summary.modules} functions=#{summary.functions}")

    IO.puts(
      "  call_graph=#{summary.call_graph_vertices} vertices/#{summary.call_graph_edges} edges"
    )

    IO.puts("  pdg=#{summary.graph_nodes} nodes/#{summary.graph_edges} edges")

    Enum.each(sections, fn {key, data} ->
      IO.puts(Format.section(section_title(key)))
      render_text_section(key, data)
    end)
  end

  defp render_oneline_map(%{summary: summary, sections: sections}) do
    IO.puts(
      "summary modules=#{summary.modules} functions=#{summary.functions} call_edges=#{summary.call_graph_edges} graph_edges=#{summary.graph_edges}"
    )

    Enum.each(sections, fn
      {:modules, modules} ->
        Enum.each(
          modules,
          &IO.puts("module #{&1.name} functions=#{&1.functions} complexity=#{&1.complexity}")
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

      {:effects, effects} ->
        Enum.each(effects, fn {effect, count} -> IO.puts("effect #{effect}=#{count}") end)

      {:data, data} ->
        Enum.each(data.top_functions, &IO.puts("data #{&1.function} edges=#{&1.data_edges}"))

      {:coupling, data} ->
        Enum.each(
          data.modules,
          &IO.puts("coupling #{&1.name} ca=#{&1.afferent} ce=#{&1.efferent} i=#{&1.instability}")
        )

      {:depth, rows} ->
        Enum.each(rows, &IO.puts("depth #{&1.function} branches=#{&1.branch_count}"))
    end)
  end

  defp render_text_section(:modules, modules) do
    Enum.each(modules, fn module ->
      IO.puts(
        "  #{Format.bright(module.name)} functions=#{module.functions} public=#{module.public} private=#{module.private} complexity=#{module.complexity}"
      )

      IO.puts("    #{Format.faint(module.file)}")
    end)
  end

  defp render_text_section(:hotspots, hotspots) do
    Enum.each(hotspots, fn hotspot ->
      IO.puts(
        "  #{Format.bright(hotspot.function)} score=#{hotspot.score} branches=#{hotspot.branches} callers=#{hotspot.callers}"
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

  defp render_text_section(:effects, effects) do
    Enum.each(effects, fn {effect, count} -> IO.puts("  #{effect}: #{count}") end)
  end

  defp render_text_section(:boundaries, boundaries) do
    Enum.each(boundaries, fn boundary ->
      IO.puts("  #{Format.bright(boundary.function)} effects=#{Enum.join(boundary.effects, "+")}")
      IO.puts("    #{Format.faint("#{boundary.file}:#{boundary.line}")}")
    end)
  end

  defp render_text_section(:depth, rows) do
    Enum.each(rows, fn row ->
      IO.puts("  #{Format.bright(row.function)} branches=#{row.branch_count}")
      IO.puts("    #{Format.faint("#{row.file}:#{row.line}")}")
    end)
  end

  defp render_text_section(:data, data) do
    IO.puts("  total_data_edges=#{data.total_data_edges}")

    Enum.each(data.top_functions, fn row ->
      IO.puts("  #{Format.bright(row.function)} data_edges=#{row.data_edges}")
      IO.puts("    #{Format.faint("#{row.file}:#{row.line}")}")
    end)
  end

  defp section_title(:modules), do: "Modules"
  defp section_title(:hotspots), do: "Hotspots"
  defp section_title(:coupling), do: "Coupling"
  defp section_title(:effects), do: "Effects"
  defp section_title(:boundaries), do: "Effect Boundaries"
  defp section_title(:depth), do: "Control Depth"
  defp section_title(:data), do: "Data Flow"

  defp selected_keys(opts) do
    [:modules, :coupling, :hotspots, :effects, :boundaries, :depth, :data, :xref]
    |> Enum.filter(&opts[&1])
    |> Enum.map(fn
      :xref -> :data
      key -> key
    end)
    |> Enum.uniq()
  end

  defp summary(project, path) do
    funcs = function_defs(project, path)
    modules = module_defs(project, path)
    effects = effect_counts(funcs)

    %{
      modules: length(modules),
      functions: length(funcs),
      call_graph_vertices: Graph.num_vertices(project.call_graph),
      call_graph_edges: Graph.num_edges(project.call_graph),
      graph_nodes: map_size(project.nodes),
      graph_edges: Graph.num_edges(project.graph),
      effects: Map.new(effects, fn {effect, count} -> {to_string(effect), count} end)
    }
  end

  defp section_data(project, :modules, opts, path) do
    project
    |> module_metrics(path)
    |> sort_modules(opts[:sort])
    |> Enum.take(opts[:top] || 50)
  end

  defp section_data(project, :hotspots, opts, path) do
    project
    |> hotspot_metrics(path)
    |> Enum.take(opts[:top] || 20)
  end

  defp section_data(project, :coupling, opts, path) do
    coupling = coupling_metrics(project, path)

    %{
      modules: coupling.modules |> sort_coupling(opts[:sort]) |> Enum.take(opts[:top] || 50),
      cycles: coupling.cycles |> Enum.take(opts[:top] || 20)
    }
  end

  defp section_data(project, :effects, _opts, path) do
    project
    |> function_defs(path)
    |> effect_counts()
    |> Map.new(fn {effect, count} -> {to_string(effect), count} end)
  end

  defp section_data(project, :boundaries, opts, path) do
    project
    |> function_defs(path)
    |> Enum.map(fn func -> {func, function_effects(func) -- [:pure]} end)
    |> Enum.filter(fn {_func, effects} -> length(effects) >= 2 end)
    |> Enum.sort_by(fn {func, effects} -> {-length(effects), location_sort(func)} end)
    |> Enum.take(opts[:top] || 20)
    |> Enum.map(fn {func, effects} ->
      %{
        function: func_id(func),
        file: func.source_span && func.source_span.file,
        line: func.source_span && func.source_span.start_line,
        effects: Enum.map(effects, &to_string/1)
      }
    end)
  end

  defp section_data(project, :depth, opts, path) do
    project
    |> function_defs(path)
    |> Enum.map(fn func ->
      %{
        function: func_id(func),
        file: func.source_span && func.source_span.file,
        line: func.source_span && func.source_span.start_line,
        branch_count: branch_count(func)
      }
    end)
    |> Enum.sort_by(& &1.branch_count, :desc)
    |> Enum.take(opts[:top] || 20)
  end

  defp section_data(project, :data, opts, path) do
    data_edges =
      project.graph
      |> Graph.edges()
      |> Enum.filter(&Analysis.data_edge?/1)

    top_functions =
      project
      |> function_defs(path)
      |> Enum.map(fn func ->
        ids = func |> IR.all_nodes() |> MapSet.new(& &1.id)
        count = Enum.count(data_edges, &(&1.v1 in ids or &1.v2 in ids))

        %{
          function: func_id(func),
          file: func.source_span && func.source_span.file,
          line: func.source_span && func.source_span.start_line,
          data_edges: count
        }
      end)
      |> Enum.sort_by(& &1.data_edges, :desc)
      |> Enum.take(opts[:top] || 20)

    %{
      total_data_edges: length(data_edges),
      top_functions: top_functions
    }
  end

  defp section_data(project, :xref, opts, path), do: section_data(project, :data, opts, path)

  defp function_defs(project, path) do
    project.nodes
    |> Map.values()
    |> Enum.filter(&(&1.type == :function_def and Project.file_matches?(span_file(&1), path)))
  end

  defp module_defs(project, path) do
    project.nodes
    |> Map.values()
    |> Enum.filter(&(&1.type == :module_def and Project.file_matches?(span_file(&1), path)))
  end

  defp module_metrics(project, path) do
    project
    |> module_defs(path)
    |> Enum.map(fn module ->
      funcs = module |> IR.all_nodes() |> Enum.filter(&(&1.type == :function_def))

      %{
        name: inspect(module.meta[:name]),
        file: span_file(module),
        functions: length(funcs),
        public: Enum.count(funcs, &(&1.meta[:kind] == :def)),
        private: Enum.count(funcs, &(&1.meta[:kind] in [:defp, :defmacrop])),
        complexity: Enum.map(funcs, &branch_count/1) |> Enum.sum()
      }
    end)
    |> Enum.reject(&(&1.functions == 0))
  end

  defp hotspot_metrics(project, path) do
    project
    |> function_defs(path)
    |> Enum.map(fn func ->
      callers =
        Project.callers(project, {func.meta[:module], func.meta[:name], func.meta[:arity]}, 1)

      branches = branch_count(func)

      %{
        function: func_id(func),
        file: span_file(func),
        line: func.source_span && func.source_span.start_line,
        branches: branches,
        callers: length(callers),
        score: branches * length(callers)
      }
    end)
    |> Enum.filter(&(&1.score > 0))
    |> Enum.sort_by(& &1.score, :desc)
  end

  defp coupling_metrics(project, path) do
    module_nodes = module_defs(project, path)
    internal = MapSet.new(module_defs(project, nil), & &1.meta[:name])
    deps = module_dependency_map(module_nodes, internal)
    afferent = invert_deps(deps)

    modules =
      Enum.map(module_nodes, fn module ->
        name = module.meta[:name]
        ce = Map.get(deps, name, []) |> length()
        ca = Map.get(afferent, name, []) |> length()
        total = ca + ce

        %{
          name: inspect(name),
          file: span_file(module),
          afferent: ca,
          efferent: ce,
          instability: if(total == 0, do: 0.0, else: Float.round(ce / total, 2))
        }
      end)

    cycles =
      deps
      |> Map.keys()
      |> Enum.flat_map(&walk_cycle(deps, &1, &1, [], 5))
      |> Enum.map(fn cycle -> %{modules: cycle |> Enum.map(&inspect/1) |> Enum.sort()} end)
      |> Enum.uniq()

    %{modules: modules, cycles: cycles}
  end

  defp module_dependency_map(module_nodes, internal) do
    module_by_file = Map.new(module_nodes, &{span_file(&1), &1.meta[:name]})

    module_nodes
    |> Enum.map(fn module -> {module.meta[:name], []} end)
    |> Map.new()
    |> then(fn seed ->
      module_nodes
      |> Enum.flat_map(&IR.all_nodes/1)
      |> Enum.filter(&(&1.type == :call and &1.meta[:kind] == :remote and &1.meta[:module]))
      |> Enum.reduce(seed, &add_module_dependency(&1, &2, module_by_file, internal))
    end)
    |> Map.new(fn {module, deps} -> {module, deps |> Enum.uniq() |> Enum.sort()} end)
  end

  defp add_module_dependency(call, acc, module_by_file, internal) do
    caller = call.source_span && Map.get(module_by_file, call.source_span.file)
    callee = call.meta[:module]

    if caller && callee && caller != callee && MapSet.member?(internal, callee) do
      Map.update(acc, caller, [callee], &[callee | &1])
    else
      acc
    end
  end

  defp invert_deps(deps) do
    Enum.reduce(deps, %{}, fn {module, module_deps}, acc ->
      Enum.reduce(module_deps, acc, fn dep, inner ->
        Map.update(inner, dep, [module], &[module | &1])
      end)
    end)
  end

  defp walk_cycle(_deps, _start, _current, path, max) when length(path) >= max, do: []

  defp walk_cycle(deps, start, current, path, max) do
    deps
    |> Map.get(current, [])
    |> Enum.flat_map(fn next ->
      cond do
        next == start and path != [] -> [Enum.reverse([current | path])]
        next in path -> []
        true -> walk_cycle(deps, start, next, [current | path], max)
      end
    end)
  end

  defp effect_counts(functions) do
    functions
    |> Enum.flat_map(&function_effects/1)
    |> Enum.frequencies()
    |> Enum.sort_by(fn {effect, _count} -> to_string(effect) end)
  end

  defp function_effects(func) do
    func
    |> IR.all_nodes()
    |> Enum.map(&Effects.classify/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp branch_count(func) do
    func
    |> IR.all_nodes()
    |> Enum.count(
      &(&1.type in [:case, :receive, :try] or
          (&1.type == :binary_op and &1.meta[:operator] in [:and, :or, :&&, :||]))
    )
  end

  defp sort_modules(modules, "functions"), do: Enum.sort_by(modules, & &1.functions, :desc)
  defp sort_modules(modules, "complexity"), do: Enum.sort_by(modules, & &1.complexity, :desc)
  defp sort_modules(modules, _), do: Enum.sort_by(modules, & &1.name)

  defp sort_coupling(modules, "afferent"), do: Enum.sort_by(modules, & &1.afferent, :desc)
  defp sort_coupling(modules, "efferent"), do: Enum.sort_by(modules, & &1.efferent, :desc)
  defp sort_coupling(modules, _), do: Enum.sort_by(modules, & &1.instability, :desc)

  defp func_id(func),
    do: Format.func_id_to_string({func.meta[:module], func.meta[:name], func.meta[:arity]})

  defp span_file(node), do: node.source_span && node.source_span.file

  defp location_sort(func),
    do: {span_file(func) || "", (func.source_span && func.source_span.start_line) || 0}

  defp ensure_json_encoder! do
    unless Code.ensure_loaded?(Jason) do
      Mix.raise("Jason is required for JSON output. Add {:jason, \"~> 1.0\"} to your deps.")
    end
  end
end
