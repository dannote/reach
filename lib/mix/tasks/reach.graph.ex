defmodule Mix.Tasks.Reach.Graph do
  @moduledoc """
  Renders a function's control flow graph in the terminal using box-drawing
  characters. Requires the optional `boxart` dependency.

      mix reach.graph Module.function/arity
      mix reach.graph lib/my_app/server.ex:45

  ## Options

    * `--call-graph` — render the call graph around the function instead of CFG

  ## Examples

      mix reach.graph MyApp.Server.handle_call/3
      mix reach.graph MyApp.Server.handle_call/3 --call-graph

  """

  use Mix.Task

  alias Reach.CLI.{BoxartGraph, Format, Project}

  @shortdoc "Render control flow graph in terminal (requires boxart)"

  @switches [call_graph: :boolean]

  @impl Mix.Task
  def run(args) do
    unless BoxartGraph.available?() do
      Mix.raise("boxart is required. Add {:boxart, \"~> 0.3\"} to your deps.")
    end

    {opts, target_args, _} = OptionParser.parse(args, switches: @switches)

    unless target_args != [] do
      Mix.raise("Usage: mix reach.graph Module.function/arity")
    end

    project = Project.load()
    raw = hd(target_args)

    if opts[:call_graph] do
      render_call_graph(project, raw)
    else
      render_cfg(project, raw)
    end
  end

  defp render_call_graph(project, raw) do
    target = Project.resolve_function(project, raw)

    unless target do
      Mix.raise("Function not found: #{raw}")
    end

    BoxartGraph.render_call_graph(project, target, 2)
  end

  defp render_cfg(project, raw) do
    # Support both Module.function/arity and file:line
    case Regex.run(~r/^(.+):(\d+)$/, raw) do
      [_, file, line_str] ->
        render_cfg_from_location(project, file, String.to_integer(line_str))

      nil ->
        target = Project.resolve_function(project, raw)
        unless target, do: Mix.raise("Function not found: #{raw}")
        render_cfg_from_mfa(project, target)
    end
  end

  defp render_cfg_from_mfa(project, {mod, fun, arity}) do
    nodes = Map.values(project.nodes)

    func_node =
      Enum.find(nodes, fn n ->
        n.type == :function_def and n.meta[:name] == fun and n.meta[:arity] == arity and
          ((mod == nil and n.meta[:module] == nil) or n.meta[:module] == mod)
      end)

    unless func_node do
      Mix.raise("Function definition not found in IR")
    end

    file = func_node.source_span && func_node.source_span.file
    IO.puts(Format.header("#{fun}/#{arity}"))

    if file do
      BoxartGraph.render_cfg(func_node, file)
    else
      IO.puts("  (no source file available)")
    end
  end

  defp render_cfg_from_location(project, file, line) do
    nodes = Map.values(project.nodes)

    func_node =
      nodes
      |> Enum.filter(fn n ->
        n.type == :function_def and n.source_span != nil and
          (n.source_span.file == file or String.ends_with?(n.source_span.file, "/" <> file)) and
          n.source_span.start_line <= line
      end)
      |> Enum.max_by(& &1.source_span.start_line, fn -> nil end)

    unless func_node do
      Mix.raise("No function found at #{file}:#{line}")
    end

    name = func_node.meta[:name]
    arity = func_node.meta[:arity]
    IO.puts(Format.header("#{name}/#{arity}"))
    BoxartGraph.render_cfg(func_node, func_node.source_span.file)
  end
end
