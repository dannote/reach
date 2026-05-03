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

  alias Reach.CLI.Pipe

  alias Reach.CLI.{BoxartGraph, Deprecation, Format, Project}

  @shortdoc "Deprecated: Render control flow graph in terminal (requires boxart)"

  @dialyzer {:nowarn_function, render_cfg: 2}

  @switches [call_graph: :boolean]

  @impl Mix.Task
  def run(args) do
    Pipe.safely(fn ->
      Deprecation.warn("reach.graph TARGET", "reach.inspect TARGET --graph")

      BoxartGraph.require!("mix reach.graph")

      {opts, target_args, _} = OptionParser.parse(args, switches: @switches)

      unless target_args != [] do
        Mix.raise("Usage: mix reach.graph Module.function/arity")
      end

      project = Project.load()
      raw = hd(target_args)
      target = Project.resolve_target(project, raw)
      unless target, do: Mix.raise("Function not found: #{raw}")

      if opts[:call_graph] do
        BoxartGraph.render_call_graph(project, target, 2)
      else
        render_cfg(project, target)
      end
    end)
  end

  defp render_cfg(project, {mod, fun, arity}) do
    func_node = Project.find_function(project, {mod, fun, arity})
    unless func_node, do: Mix.raise("Function definition not found in IR")

    file = func_node.source_span && func_node.source_span.file
    IO.puts(Format.header("#{fun}/#{arity}"))

    if file do
      BoxartGraph.render_cfg(func_node, file)
    else
      IO.puts("  (no source file available)")
    end
  end
end
