defmodule Mix.Tasks.Reach.Map do
  @moduledoc """
  Shows a project-level map of modules, coupling, hotspots, depth, effects, boundaries, and data-flow summaries.
  """

  use Mix.Task

  alias Reach.CLI.Commands.Map
  alias Reach.CLI.Options
  alias Reach.CLI.Pipe

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
    Pipe.safely(fn ->
      {opts, positional} = Options.parse(args, @switches, @aliases)
      Map.run(opts, positional)
    end)
  end
end
