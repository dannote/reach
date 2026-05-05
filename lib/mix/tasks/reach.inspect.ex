defmodule Mix.Tasks.Reach.Inspect do
  @moduledoc """
  Explains one function, module, file, or line.
  """

  use Mix.Task

  alias Reach.CLI.Commands.Inspect
  alias Reach.CLI.Options
  alias Reach.CLI.Pipe

  @shortdoc "Inspect one target's dependencies, impact, slices, and context"

  @switches [
    format: :string,
    deps: :boolean,
    impact: :boolean,
    slice: :boolean,
    forward: :boolean,
    graph: :boolean,
    call_graph: :boolean,
    data: :boolean,
    context: :boolean,
    candidates: :boolean,
    why: :string,
    depth: :integer,
    variable: :string,
    limit: :integer,
    all: :boolean
  ]

  @aliases [f: :format]

  @impl Mix.Task
  def run(args) do
    Pipe.safely(fn ->
      {opts, target_args} = Options.parse(args, @switches, @aliases)
      Inspect.run(opts, target_args)
    end)
  end
end
