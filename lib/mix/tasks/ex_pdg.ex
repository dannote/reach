defmodule Mix.Tasks.ExPdg do
  @moduledoc """
  Analyzes Elixir source files using ExPDG.

      mix ex_pdg [files...] [--check] [--slice NODE_ID] [--dot FILE]

  ## Options

    * `--check` — run all built-in checks and report diagnostics
    * `--stats` — print graph statistics (nodes, edges, functions)
    * `--dot FILE` — export the PDG to a DOT file
    * `--verbose` — show detailed output
  """

  use Mix.Task

  alias ExPDG.{Check, Diagnostic, IR, SystemDependence}

  alias ExPDG.Checks.{
    DeepDependencyChain,
    TaintFlow,
    UnusedDefinition,
    UselessExpression
  }

  @built_in_checks [
    UselessExpression,
    UnusedDefinition,
    TaintFlow,
    DeepDependencyChain
  ]

  @impl Mix.Task
  def run(args) do
    {opts, files, _} =
      OptionParser.parse(args,
        strict: [check: :boolean, stats: :boolean, dot: :string, verbose: :boolean],
        aliases: [c: :check, s: :stats, v: :verbose]
      )

    files = expand_files(files)

    if files == [] do
      Mix.shell().info("Usage: mix ex_pdg [files...] [--check] [--stats] [--dot FILE]")
      Mix.shell().info("       mix ex_pdg lib/ --check")
      exit({:shutdown, 1})
    end

    results =
      Enum.map(files, fn file ->
        analyze_file(file, opts)
      end)

    if opts[:check] do
      report_diagnostics(results)
    end

    if opts[:stats] do
      report_stats(results)
    end

    if dot_file = opts[:dot] do
      export_dot(results, dot_file)
    end

    if !opts[:check] && !opts[:stats] && !opts[:dot] do
      report_stats(results)
    end
  end

  defp expand_files([]), do: []

  defp expand_files(paths) do
    Enum.flat_map(paths, fn path ->
      cond do
        File.dir?(path) ->
          Path.wildcard(Path.join(path, "**/*.ex"))

        File.exists?(path) and String.ends_with?(path, ".ex") ->
          [path]

        true ->
          Mix.shell().error("Not found: #{path}")
          []
      end
    end)
    |> Enum.sort()
  end

  defp analyze_file(file, opts) do
    source = File.read!(file)

    case IR.from_string(source, file: file) do
      {:ok, ir_nodes} ->
        sdg = SystemDependence.build(ir_nodes, module: infer_module(file))

        diagnostics =
          if opts[:check] do
            Check.run_checks(@built_in_checks, sdg)
          else
            []
          end

        func_count =
          ir_nodes
          |> IR.all_nodes()
          |> Enum.count(&(&1.type == :function_def))

        %{
          file: file,
          sdg: sdg,
          diagnostics: diagnostics,
          node_count: map_size(sdg.nodes),
          edge_count: sdg.graph |> Graph.edges() |> length(),
          function_count: func_count,
          error: nil
        }

      {:error, reason} ->
        if opts[:verbose] do
          Mix.shell().error("Parse error in #{file}: #{inspect(reason)}")
        end

        %{
          file: file,
          sdg: nil,
          diagnostics: [],
          node_count: 0,
          edge_count: 0,
          function_count: 0,
          error: reason
        }
    end
  end

  defp report_diagnostics(results) do
    all_diagnostics =
      results
      |> Enum.flat_map(& &1.diagnostics)
      |> Enum.sort_by(fn d ->
        {severity_order(d.severity), d.location[:file] || "", d.location[:start_line] || 0}
      end)

    if all_diagnostics == [] do
      Mix.shell().info("No issues found.")
    else
      Enum.each(all_diagnostics, &print_diagnostic/1)

      counts = Enum.frequencies_by(all_diagnostics, & &1.severity)

      Mix.shell().info(
        "\n#{length(all_diagnostics)} issue(s): " <>
          "#{Map.get(counts, :error, 0)} error, " <>
          "#{Map.get(counts, :warning, 0)} warning, " <>
          "#{Map.get(counts, :info, 0)} info"
      )
    end
  end

  defp print_diagnostic(%Diagnostic{} = d) do
    location =
      case d.location do
        %{file: file, start_line: line} when file != nil ->
          "#{Path.relative_to_cwd(file)}:#{line}"

        _ ->
          "unknown"
      end

    severity_label =
      case d.severity do
        :error -> IO.ANSI.red() <> "error" <> IO.ANSI.reset()
        :warning -> IO.ANSI.yellow() <> "warning" <> IO.ANSI.reset()
        :info -> IO.ANSI.cyan() <> "info" <> IO.ANSI.reset()
      end

    Mix.shell().info("#{location}: [#{severity_label}] #{d.message}")
  end

  defp severity_order(:error), do: 0
  defp severity_order(:warning), do: 1
  defp severity_order(:info), do: 2

  defp report_stats(results) do
    successful = Enum.reject(results, & &1.error)
    failed = Enum.filter(results, & &1.error)

    total_nodes = Enum.sum(Enum.map(successful, & &1.node_count))
    total_edges = Enum.sum(Enum.map(successful, & &1.edge_count))
    total_functions = Enum.sum(Enum.map(successful, & &1.function_count))

    Mix.shell().info("ExPDG Analysis")
    Mix.shell().info("  Files analyzed: #{length(successful)}")

    if failed != [] do
      Mix.shell().info("  Files with parse errors: #{length(failed)}")
    end

    Mix.shell().info("  Functions: #{total_functions}")
    Mix.shell().info("  IR nodes: #{total_nodes}")
    Mix.shell().info("  Dependence edges: #{total_edges}")
  end

  defp export_dot(results, dot_file) do
    successful = Enum.reject(results, & &1.error)

    case successful do
      [result] ->
        {:ok, dot} = Graph.to_dot(result.sdg.graph)
        File.write!(dot_file, dot)
        Mix.shell().info("DOT exported to \#{dot_file}")

      _ ->
        Mix.shell().error("--dot requires exactly one file")
    end
  end

  defp infer_module(file) do
    file
    |> Path.rootname()
    |> Path.split()
    |> Enum.drop_while(&(&1 != "lib"))
    |> Enum.drop(1)
    |> Enum.map_join(".", &Macro.camelize/1)
    |> then(fn
      "" -> nil
      name -> Module.concat([name])
    end)
  end
end
