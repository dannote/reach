defmodule Reach.CLI.Commands.Inspect.Deps do
  @moduledoc false

  alias Reach.CLI.BoxartGraph
  alias Reach.CLI.Project
  alias Reach.CLI.Render.Inspect.Deps, as: DepsRender
  alias Reach.Inspect.Deps, as: DepsAnalysis
  alias Reach.Project.Query

  def run_target(raw_target, opts, command \\ "reach.inspect") do
    project = Project.load(quiet: opts[:format] == "json")
    target = Query.resolve_target(project, raw_target)

    unless target do
      Mix.raise("Function not found: #{raw_target}")
    end

    depth = opts[:depth] || 3
    result = DepsAnalysis.analyze(project, target, depth)
    render(result, project, target, depth, opts, command)
  end

  defp render(_result, project, target, depth, %{graph: true}, _command) do
    BoxartGraph.require!()
    BoxartGraph.render_call_graph(project, target, depth)
  end

  defp render(result, _project, _target, _depth, opts, command) do
    DepsRender.render(result, opts[:format] || "text", command)
  end
end
