defmodule Reach.CLI.Commands.Inspect.Impact do
  @moduledoc false

  alias Reach.CLI.BoxartGraph
  alias Reach.CLI.Project
  alias Reach.CLI.Render.Inspect.Impact, as: ImpactRender
  alias Reach.Inspect.Impact, as: ImpactAnalysis
  alias Reach.Project.Query

  def run_target(raw_target, opts, command \\ "reach.inspect") do
    project = Project.load(quiet: opts[:format] == "json")
    target = Query.resolve_target(project, raw_target)

    unless target do
      Mix.raise("Function not found: #{raw_target}")
    end

    depth = opts[:depth] || 4
    result = ImpactAnalysis.analyze(project, target, depth)
    render(project, target, depth, result, opts, command)
  end

  defp render(project, target, depth, _result, %{graph: true}, _command) do
    BoxartGraph.require!()
    BoxartGraph.render_caller_graph(project, target, depth)
  end

  defp render(project, _target, _depth, result, opts, command) do
    ImpactRender.render(project, result, opts[:format] || "text", command)
  end
end
