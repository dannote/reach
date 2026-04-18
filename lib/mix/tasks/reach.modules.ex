defmodule Mix.Tasks.Reach.Modules do
  @moduledoc """
  Lists all modules with their public functions, behaviours, and
  complexity metrics. Gives the agent a bird's-eye view of the codebase.

      mix reach.modules
      mix reach.modules --format json
      mix reach.modules --sort complexity

  ## Options

    * `--format` — output format: `text` (default), `json`, `oneline`
    * `--sort` — sort by: `name` (default), `functions`, `complexity`

  """

  use Mix.Task

  alias Reach.CLI.Format
  alias Reach.CLI.Project

  @shortdoc "List all modules with functions and metrics"

  @switches [format: :string, sort: :string]
  @aliases [f: :format]

  @impl Mix.Task
  def run(args) do
    {opts, _args, _} = OptionParser.parse(args, switches: @switches, aliases: @aliases)
    format = opts[:format] || "text"
    sort = opts[:sort] || "name"

    project = Project.load()
    modules = analyze_modules(project)
    modules = modules |> Enum.reject(&(&1.total_functions == 0)) |> sort_modules(sort)

    case format do
      "json" ->
        Format.render(%{modules: modules}, "reach.modules", format: "json", pretty: true)

      "oneline" ->
        Enum.each(modules, fn m ->
          IO.puts(
            "#{m.name} #{m.public_count} public #{m.private_count} private complexity=#{m.total_complexity}"
          )
        end)

      _ ->
        render_text(modules)
    end
  end

  defp analyze_modules(project) do
    nodes = Map.values(project.nodes)
    cg = project.call_graph

    modules =
      nodes
      |> Enum.filter(&(&1.type == :module_def))
      |> Enum.uniq_by(& &1.meta[:name])

    Enum.map(modules, fn mod ->
      mod_nodes = Reach.IR.all_nodes(mod)

      func_defs =
        Enum.filter(mod_nodes, &(&1.type == :function_def))

      public = Enum.filter(func_defs, &(&1.meta[:kind] == :def))
      private = Enum.filter(func_defs, &(&1.meta[:kind] in [:defp, :defmacrop]))
      macros = Enum.filter(func_defs, &(&1.meta[:kind] == :defmacro))

      total_complexity =
        func_defs
        |> Enum.map(&count_branches/1)
        |> Enum.sum()

      biggest_fn = func_defs |> Enum.max_by(&count_branches/1, fn -> nil end)

      callbacks = detect_callbacks(mod_nodes)
      file = if mod.source_span, do: mod.source_span.file, else: nil

      fan_in = count_fan_in(cg, func_defs)
      fan_out = count_fan_out(cg, func_defs)

      %{
        name: inspect(mod.meta[:name]),
        file: file,
        public_count: length(public),
        private_count: length(private),
        macro_count: length(macros),
        total_functions: length(func_defs),
        total_complexity: total_complexity,
        biggest_function:
          if(biggest_fn,
            do:
              "#{biggest_fn.meta[:name]}/#{biggest_fn.meta[:arity]} (#{count_branches(biggest_fn)})",
            else: nil
          ),
        callbacks: callbacks,
        fan_in: fan_in,
        fan_out: fan_out
      }
    end)
  end

  defp count_branches(func_def) do
    func_def
    |> Reach.IR.all_nodes()
    |> Enum.count(fn n ->
      n.type in [:case, :clause] or
        (n.type == :binary_op and n.meta[:operator] in [:and, :or, :&&, :||])
    end)
  end

  defp detect_callbacks(mod_nodes) do
    callbacks =
      mod_nodes
      |> Enum.filter(fn n ->
        n.type == :function_def and
          n.meta[:name] in [
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
      end)
      |> Enum.map(& &1.meta[:name])
      |> Enum.uniq()

    behaviour = infer_behaviour(callbacks)
    if behaviour, do: [behaviour | callbacks], else: callbacks
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

  defp count_fan_in(cg, func_defs) do
    func_defs
    |> Enum.map(fn f ->
      v = {nil, f.meta[:name], f.meta[:arity]}
      if Graph.has_vertex?(cg, v), do: length(Graph.in_neighbors(cg, v)), else: 0
    end)
    |> Enum.sum()
  end

  defp count_fan_out(cg, func_defs) do
    func_defs
    |> Enum.map(fn f ->
      v = {nil, f.meta[:name], f.meta[:arity]}
      if Graph.has_vertex?(cg, v), do: length(Graph.out_neighbors(cg, v)), else: 0
    end)
    |> Enum.sum()
  end

  defp sort_modules(modules, "functions"), do: Enum.sort_by(modules, & &1.total_functions, :desc)

  defp sort_modules(modules, "complexity"),
    do: Enum.sort_by(modules, & &1.total_complexity, :desc)

  defp sort_modules(modules, _), do: Enum.sort_by(modules, & &1.name)

  defp complexity_color(c) when c > 200, do: Format.red(to_string(c))
  defp complexity_color(c) when c > 50, do: Format.yellow(to_string(c))
  defp complexity_color(c), do: to_string(c)

  defp render_text(modules) do
    IO.puts(Format.header("Modules (#{length(modules)})"))

    Enum.each(modules, fn m ->
      behaviours =
        case m.callbacks do
          [] -> ""
          [behaviour | _] when is_binary(behaviour) -> " (#{behaviour})"
          _ -> ""
        end

      IO.puts("  #{Format.bright(m.name)}#{Format.cyan(behaviours)}")

      IO.puts(
        "    #{m.public_count} public, #{m.private_count} private, complexity #{complexity_color(m.total_complexity)}"
      )

      if m.biggest_function do
        IO.puts("    biggest: #{Format.yellow(m.biggest_function)}")
      end

      if m.file do
        IO.puts("    #{Format.faint(m.file)}")
      end

      IO.puts("")
    end)

    total_pub = Enum.sum(Enum.map(modules, & &1.public_count))
    total_priv = Enum.sum(Enum.map(modules, & &1.private_count))
    total_complex = Enum.sum(Enum.map(modules, & &1.total_complexity))

    IO.puts(
      "#{length(modules)} modules, #{total_pub} public + #{total_priv} private functions, total complexity #{total_complex}"
    )
  end
end
