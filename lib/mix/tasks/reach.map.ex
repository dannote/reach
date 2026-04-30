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

  alias Reach.Analysis
  alias Reach.CLI.BoxartGraph
  alias Reach.CLI.Format
  alias Reach.CLI.Project
  alias Reach.ControlFlow
  alias Reach.Dominator
  alias Reach.Effects
  alias Reach.IR
  alias Reach.IR.Helpers, as: IRHelpers

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
      if sections == [], do: [:modules, :hotspots, :coupling, :boundaries], else: sections

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
          IO.puts(Jason.encode!(result, pretty: true))

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

      Enum.each(sections, fn {key, data} ->
        IO.puts(Format.section(section_title(key)))
        render_text_section(key, data)
      end)
    end
  end

  defp render_oneline_map(%{summary: summary, sections: sections}) do
    IO.puts(
      "summary modules=#{summary.modules} functions=#{summary.functions} call_edges=#{summary.call_graph_edges} graph_edges=#{summary.graph_edges}"
    )

    Enum.each(sections, fn
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

    Enum.each(data.top_functions, fn row ->
      IO.puts("  #{Format.bright(row.function)} data_edges=#{row.data_edges}")
      IO.puts("    #{Format.faint("#{row.file}:#{row.line}")}")
    end)

    if Map.get(data, :cross_function_edges, []) != [] do
      IO.puts("  cross-function edges:")

      Enum.each(data.cross_function_edges, fn row ->
        IO.puts("    #{Format.bright(row.from)} -> #{Format.bright(row.to)} edges=#{row.edges}")
      end)
    end
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

    modules =
      coupling.modules
      |> maybe_filter_orphans(opts[:orphans])
      |> sort_coupling(opts[:sort])
      |> Enum.take(opts[:top] || 50)

    %{
      modules: modules,
      cycles: coupling.cycles |> Enum.take(opts[:top] || 20)
    }
  end

  defp section_data(project, :effects, opts, path) do
    project
    |> call_nodes(path, opts[:module])
    |> effect_summary(opts[:top] || 20)
  end

  defp section_data(project, :boundaries, opts, path) do
    min = opts[:min] || 2

    project
    |> function_defs(path)
    |> Enum.map(fn func -> {func, function_effects(func) -- [:pure, :unknown]} end)
    |> Enum.filter(fn {_func, effects} -> length(effects) >= min end)
    |> Enum.sort_by(fn {func, effects} -> {-length(effects), location_sort(func)} end)
    |> Enum.take(opts[:top] || 20)
    |> Enum.map(fn {func, effects} ->
      module = inspect(func.meta[:module])
      function = "#{func.meta[:name]}/#{func.meta[:arity]}"

      %{
        module: module,
        function: function,
        display_function: "#{module}.#{function}",
        file: func.source_span && func.source_span.file,
        line: func.source_span && func.source_span.start_line,
        effects: Enum.map(effects, &to_string/1),
        calls: effect_calls(func)
      }
    end)
  end

  defp section_data(project, :depth, opts, path) do
    project
    |> function_defs(path)
    |> Enum.flat_map(&depth_metric/1)
    |> Enum.sort_by(& &1.depth, :desc)
    |> Enum.take(opts[:top] || 20)
  end

  defp section_data(project, :data, opts, path) do
    data_edges =
      project.graph
      |> Graph.edges()
      |> Enum.filter(&Analysis.data_edge?/1)

    func_index = build_func_index(project)
    edge_counts = data_edge_counts(data_edges, func_index)
    top = opts[:top] || 20

    top_functions =
      project
      |> function_defs(path)
      |> Enum.map(fn func ->
        id = function_id(func)

        %{
          function: func_id(func),
          file: func.source_span && func.source_span.file,
          line: func.source_span && func.source_span.start_line,
          data_edges: Map.get(edge_counts, id, 0)
        }
      end)
      |> Enum.sort_by(& &1.data_edges, :desc)
      |> Enum.take(top)

    %{
      total_data_edges: length(data_edges),
      top_functions: top_functions,
      cross_function_edges: cross_function_edges(project, data_edges, top, func_index)
    }
  end

  defp section_data(project, :xref, opts, path), do: section_data(project, :data, opts, path)

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

  defp function_defs(project, path) do
    project.nodes
    |> Map.values()
    |> Enum.filter(&(&1.type == :function_def and Project.file_matches?(span_file(&1), path)))
  end

  defp call_nodes(project, path, module_filter) do
    module_nodes = module_defs(project, nil)

    project.nodes
    |> Map.values()
    |> Enum.filter(&(&1.type == :call and Project.file_matches?(span_file(&1), path)))
    |> filter_by_module(module_nodes, module_filter)
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

      public_count = Enum.count(funcs, &(&1.meta[:kind] == :def))
      private_count = Enum.count(funcs, &(&1.meta[:kind] in [:defp, :defmacrop]))
      macro_count = Enum.count(funcs, &(&1.meta[:kind] == :defmacro))
      total_complexity = Enum.map(funcs, &branch_count/1) |> Enum.sum()
      callbacks = detect_callbacks(module |> IR.all_nodes())

      %{
        name: inspect(module.meta[:name]),
        file: span_file(module),
        functions: length(funcs),
        public: public_count,
        private: private_count,
        complexity: total_complexity,
        public_count: public_count,
        private_count: private_count,
        macro_count: macro_count,
        total_functions: length(funcs),
        total_complexity: total_complexity,
        biggest_function: biggest_function(funcs),
        callbacks: callbacks,
        fan_in: count_fan_in(project.call_graph, funcs),
        fan_out: count_fan_out(project.call_graph, funcs)
      }
    end)
    |> Enum.reject(&(&1.functions == 0))
  end

  defp hotspot_metrics(project, path) do
    caller_counts = direct_caller_counts(project.call_graph)

    project
    |> function_defs(path)
    |> Enum.map(fn func ->
      callers = caller_count(func, caller_counts)
      branches = branch_count(func)

      module = inspect(func.meta[:module])
      function = "#{func.meta[:name]}/#{func.meta[:arity]}"

      %{
        module: module,
        function: function,
        display_function: "#{module}.#{function}",
        file: span_file(func),
        line: func.source_span && func.source_span.start_line,
        branches: branches,
        callers: callers,
        score: branches * callers,
        clauses: IRHelpers.clause_labels(func)
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

  defp direct_caller_counts(call_graph) do
    call_graph
    |> Graph.edges()
    |> Enum.filter(&(Project.mfa?(&1.v1) and Project.mfa?(&1.v2)))
    |> Enum.reduce(%{}, fn edge, acc ->
      Map.update(acc, edge.v2, MapSet.new([edge.v1]), &MapSet.put(&1, edge.v1))
    end)
    |> Map.new(fn {target, callers} -> {target, MapSet.size(callers)} end)
  end

  defp caller_count(func, caller_counts) do
    func
    |> function_vertex()
    |> function_variants()
    |> Enum.map(&Map.get(caller_counts, &1, 0))
    |> Enum.sum()
  end

  defp function_variants({module, function, arity}) do
    [{nil, function, arity}, {module, function, arity}]
    |> Enum.uniq()
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

  defp effect_summary(call_nodes, top) do
    distribution =
      call_nodes
      |> Enum.map(&Effects.classify/1)
      |> Enum.frequencies()
      |> Enum.sort_by(&elem(&1, 1), :desc)

    total = length(call_nodes)

    unknown_calls =
      call_nodes
      |> Enum.filter(&(Effects.classify(&1) == :unknown))
      |> Enum.reject(fn n ->
        is_nil(n.meta[:function]) or n.meta[:function] in [:__aliases__, :{}]
      end)
      |> Enum.map(fn n -> {n.meta[:module], n.meta[:function]} end)
      |> Enum.frequencies()
      |> Enum.sort_by(&elem(&1, 1), :desc)
      |> Enum.take(top)
      |> Enum.map(fn {{mod, fun}, count} ->
        %{
          module: if(mod, do: inspect(mod), else: "Kernel"),
          function: to_string(fun),
          count: count
        }
      end)

    %{
      total_calls: total,
      distribution:
        Enum.map(distribution, fn {effect, count} ->
          %{effect: to_string(effect), count: count, ratio: Float.round(count / max(total, 1), 3)}
        end),
      unknown_calls: unknown_calls
    }
  end

  defp function_effects(func) do
    func
    |> IR.all_nodes()
    |> Enum.map(&Effects.classify/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp depth_metric(func) do
    cfg = ControlFlow.build(func)
    idom = Dominator.idom(cfg, :entry)
    tree = Dominator.tree(idom)
    depth = max_tree_depth(tree, :entry, 0, MapSet.new())

    if depth > 0 do
      [
        %{
          module: inspect(func.meta[:module]),
          function: func_id(func),
          depth: depth,
          clauses: IRHelpers.clause_labels(func),
          file: span_file(func),
          line: func.source_span && func.source_span.start_line,
          branch_count: branch_count(func)
        }
      ]
    else
      []
    end
  rescue
    _ -> []
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

  defp data_edge_counts(data_edges, func_index) do
    Enum.reduce(data_edges, %{}, fn edge, counts ->
      source_func = Map.get(func_index, edge.v1)
      target_func = Map.get(func_index, edge.v2)

      counts
      |> increment_data_edge_count(source_func)
      |> increment_data_edge_count(if(target_func == source_func, do: nil, else: target_func))
    end)
  end

  defp increment_data_edge_count(counts, nil), do: counts
  defp increment_data_edge_count(counts, func), do: Map.update(counts, func, 1, &(&1 + 1))

  defp cross_function_edges(project, data_edges, top, func_index) do
    data_edges
    |> Enum.flat_map(fn edge ->
      source_func = Map.get(func_index, edge.v1)
      target_func = Map.get(func_index, edge.v2)
      source_node = Map.get(project.nodes, edge.v1)
      target_node = Map.get(project.nodes, edge.v2)

      if source_func && target_func && source_func != target_func do
        [
          %{
            from_func: source_func,
            to_func: target_func,
            label: normalize_label(edge.label),
            from_node: node_summary(source_node),
            to_node: node_summary(target_node)
          }
        ]
      else
        []
      end
    end)
    |> Enum.group_by(&{&1.from_func, &1.to_func})
    |> Enum.map(fn {{from, to}, edges} ->
      labels = edges |> Enum.map(& &1.label) |> Enum.frequencies()

      variables =
        edges
        |> Enum.flat_map(fn edge -> [edge.from_node, edge.to_node] end)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
        |> Enum.take(5)

      %{
        from: func_id_tuple(from),
        to: func_id_tuple(to),
        edges: Enum.sum(Map.values(labels)),
        labels: labels,
        variables: variables
      }
    end)
    |> Enum.sort_by(& &1.edges, :desc)
    |> Enum.take(top)
  end

  defp build_func_index(project) do
    project
    |> module_defs(nil)
    |> Enum.reduce(%{}, &index_module_functions/2)
  end

  defp index_module_functions(module, acc) do
    module
    |> IR.all_nodes()
    |> Enum.filter(&(&1.type == :function_def))
    |> Enum.reduce(acc, &index_function_nodes/2)
  end

  defp index_function_nodes(func, acc) do
    id = {func.meta[:module], func.meta[:name], func.meta[:arity]}

    func
    |> IR.all_nodes()
    |> Enum.reduce(acc, fn node, index -> Map.put_new(index, node.id, id) end)
  end

  defp normalize_label({label, _}), do: label
  defp normalize_label(label), do: label

  defp node_summary(nil), do: nil
  defp node_summary(%{type: :var, meta: %{name: name}}), do: to_string(name)
  defp node_summary(%{type: :call, meta: %{function: function}}), do: to_string(function)
  defp node_summary(%{type: :literal, meta: %{value: value}}), do: inspect(value)
  defp node_summary(%{type: type}), do: to_string(type)

  defp branch_count(func) do
    func
    |> IR.all_nodes()
    |> Enum.count(
      &(&1.type in [:case, :receive, :try] or
          (&1.type == :binary_op and &1.meta[:operator] in [:and, :or, :&&, :||]))
    )
  end

  defp biggest_function([]), do: nil

  defp biggest_function(funcs) do
    func = Enum.max_by(funcs, &branch_count/1)
    "#{func.meta[:name]}/#{func.meta[:arity]} (#{branch_count(func)})"
  end

  defp detect_callbacks(nodes) do
    callbacks =
      nodes
      |> Enum.filter(&callback_function?/1)
      |> Enum.map(& &1.meta[:name])
      |> Enum.uniq()

    case infer_behaviour(callbacks) do
      nil -> callbacks
      behaviour -> [behaviour | callbacks]
    end
  end

  defp callback_function?(node) do
    node.type == :function_def and
      node.meta[:name] in [
        :init,
        :handle_call,
        :handle_cast,
        :handle_info,
        :handle_continue,
        :handle_event,
        :handle_batch,
        :perform,
        :mount,
        :render,
        :handle_params
      ]
  end

  defp infer_behaviour(callbacks) do
    cond do
      :handle_call in callbacks or :handle_cast in callbacks -> "GenServer"
      :handle_event in callbacks -> "GenStage"
      :mount in callbacks and :render in callbacks -> "LiveView"
      :perform in callbacks -> "Oban.Worker"
      true -> nil
    end
  end

  defp count_fan_in(call_graph, funcs) do
    funcs
    |> Enum.map(&function_vertex/1)
    |> Enum.map(fn vertex ->
      if Graph.has_vertex?(call_graph, vertex),
        do: length(Graph.in_neighbors(call_graph, vertex)),
        else: 0
    end)
    |> Enum.sum()
  end

  defp count_fan_out(call_graph, funcs) do
    funcs
    |> Enum.map(&function_vertex/1)
    |> Enum.map(fn vertex ->
      if Graph.has_vertex?(call_graph, vertex),
        do: length(Graph.out_neighbors(call_graph, vertex)),
        else: 0
    end)
    |> Enum.sum()
  end

  defp function_vertex(func), do: {func.meta[:module], func.meta[:name], func.meta[:arity]}

  defp effect_calls(func) do
    func
    |> IR.all_nodes()
    |> Enum.filter(&(&1.type == :call))
    |> Enum.reject(&(Effects.classify(&1) in [:pure, :unknown]))
    |> Enum.map(fn call ->
      %{effect: to_string(Effects.classify(call)), call: Format.call_name(call)}
    end)
    |> Enum.uniq_by(& &1.call)
    |> Enum.sort_by(& &1.effect)
  end

  defp module_behaviour_label([]), do: ""
  defp module_behaviour_label([behaviour | _]) when is_binary(behaviour), do: " (#{behaviour})"
  defp module_behaviour_label(_callbacks), do: ""

  defp sort_modules(modules, "functions"), do: Enum.sort_by(modules, & &1.total_functions, :desc)

  defp sort_modules(modules, "complexity"),
    do: Enum.sort_by(modules, & &1.total_complexity, :desc)

  defp sort_modules(modules, _), do: Enum.sort_by(modules, & &1.name)

  defp sort_coupling(modules, "afferent"), do: Enum.sort_by(modules, & &1.afferent, :desc)
  defp sort_coupling(modules, "efferent"), do: Enum.sort_by(modules, & &1.efferent, :desc)
  defp sort_coupling(modules, _), do: Enum.sort_by(modules, & &1.instability, :desc)

  defp maybe_filter_orphans(modules, true),
    do: Enum.filter(modules, &(&1.afferent == 0 and &1.efferent > 0))

  defp maybe_filter_orphans(modules, _), do: modules

  defp filter_by_module(call_nodes, _module_nodes, nil), do: call_nodes

  defp filter_by_module(call_nodes, module_nodes, module_filter) do
    case Enum.find(module_nodes, &(to_string(&1.meta[:name]) =~ module_filter)) do
      nil ->
        call_nodes

      module ->
        call_nodes
        |> MapSet.new()
        |> MapSet.intersection(MapSet.new(IR.all_nodes(module)))
        |> MapSet.to_list()
    end
  end

  defp function_id(func), do: {func.meta[:module], func.meta[:name], func.meta[:arity]}

  defp func_id(func), do: Format.func_id_to_string(function_id(func))

  defp func_id_tuple({module, name, arity}), do: Format.func_id_to_string({module, name, arity})

  defp span_file(node), do: node.source_span && node.source_span.file

  defp location_sort(func),
    do: {span_file(func) || "", (func.source_span && func.source_span.start_line) || 0}

  defp render_effect_graph(result) do
    chart_module = Module.concat([Boxart, Render, PieChart, PieChart])

    unless Code.ensure_loaded?(chart_module) and Code.ensure_loaded?(Boxart.Render.PieChart) do
      Mix.raise("boxart is required for --graph. Add {:boxart, \"~> 0.3.3\"} to your deps.")
    end

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

  defp ensure_json_encoder! do
    unless Code.ensure_loaded?(Jason) do
      Mix.raise("Jason is required for JSON output. Add {:jason, \"~> 1.0\"} to your deps.")
    end
  end

  defp ensure_boxart! do
    unless BoxartGraph.available?() do
      Mix.raise("boxart is required for --graph. Add {:boxart, \"~> 0.3.3\"} to your deps.")
    end
  end
end
