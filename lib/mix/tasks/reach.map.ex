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

  alias Reach.CLI.Format
  alias Reach.CLI.Project
  alias Reach.CLI.TaskRunner
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

    if opts[:format] == "json" do
      render_json_map(opts, positional)
    else
      run_delegated(opts, positional)
    end
  end

  defp run_delegated(opts, path_args) do
    selections = selected_sections(opts)
    sections = if selections == [], do: default_sections(), else: selections

    Enum.each(sections, fn {title, task, extra_args} ->
      print_section(title, length(sections))
      TaskRunner.run(task, build_args(opts, extra_args, path_args))
    end)
  end

  defp render_json_map(opts, path_args) do
    ensure_json_encoder!()
    project = Project.load()
    path = List.first(path_args)
    sections = selected_keys(opts)

    sections =
      if sections == [], do: [:modules, :hotspots, :coupling, :boundaries], else: sections

    result =
      %{
        command: "reach.map",
        summary: summary(project, path),
        sections: Map.new(sections, &{&1, section_data(project, &1, opts, path)})
      }

    IO.puts(Jason.encode!(result, pretty: true))
  end

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
      |> Enum.filter(&data_edge?/1)

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
      |> Enum.reduce(seed, fn call, acc ->
        caller = call.source_span && Map.get(module_by_file, call.source_span.file)
        callee = call.meta[:module]

        if caller && callee && caller != callee && MapSet.member?(internal, callee) do
          Map.update(acc, caller, [callee], &[callee | &1])
        else
          acc
        end
      end)
    end)
    |> Map.new(fn {module, deps} -> {module, deps |> Enum.uniq() |> Enum.sort()} end)
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

  defp data_edge?(%Graph.Edge{label: {:data, _}}), do: true

  defp data_edge?(%Graph.Edge{label: label})
       when label in [:parameter_in, :parameter_out, :summary], do: true

  defp data_edge?(_edge), do: false

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

  defp selected_sections(opts) do
    [
      {:modules, "Modules", "reach.modules", []},
      {:coupling, "Coupling", "reach.coupling", []},
      {:hotspots, "Hotspots", "reach.hotspots", []},
      {:effects, "Effects", "reach.effects", []},
      {:boundaries, "Effect Boundaries", "reach.boundaries", []},
      {:depth, "Control Depth", "reach.depth", []},
      {:data, "Cross-function Data Flow", "reach.xref", []},
      {:xref, "Cross-function Data Flow", "reach.xref", []}
    ]
    |> Enum.flat_map(fn {key, title, task, extra_args} ->
      if opts[key], do: [{title, task, extra_args}], else: []
    end)
  end

  defp default_sections do
    [
      {"Modules", "reach.modules", []},
      {"Hotspots", "reach.hotspots", ["--top", "10"]},
      {"Coupling", "reach.coupling", []},
      {"Effect Boundaries", "reach.boundaries", []}
    ]
  end

  defp build_args(opts, extra_args, path_args) do
    []
    |> maybe_put("--format", opts[:format])
    |> maybe_put("--top", opts[:top])
    |> maybe_put("--sort", opts[:sort])
    |> Kernel.++(extra_args)
    |> Kernel.++(path_args)
  end

  defp maybe_put(args, _flag, nil), do: args
  defp maybe_put(args, flag, value), do: args ++ [flag, to_string(value)]

  defp print_section(_title, 1), do: :ok

  defp print_section(title, _count) do
    IO.puts("\n== #{title} ==")
  end

  defp ensure_json_encoder! do
    unless Code.ensure_loaded?(Jason) do
      Mix.raise("Jason is required for JSON output. Add {:jason, \"~> 1.0\"} to your deps.")
    end
  end
end
