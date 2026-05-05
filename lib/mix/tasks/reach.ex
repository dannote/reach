defmodule Mix.Tasks.Reach do
  @moduledoc """
  Generates an interactive HTML report for Elixir/Erlang/Gleam/JavaScript source files.
  """

  use Mix.Task

  alias Reach.CLI.Commands.Report
  alias Reach.CLI.Options
  alias Reach.CLI.Pipe

  @shortdoc "Generate interactive HTML report"

  @switches [
    output: :string,
    format: :string,
    open: :boolean,
    dead_code: :boolean
  ]

  @aliases [o: :output, f: :format]

  @impl Mix.Task
  def run(args) do
    Pipe.safely(fn ->
      {opts, files} = Options.parse(args, @switches, @aliases)
      Report.run(opts, files)
    end)
  end
end
