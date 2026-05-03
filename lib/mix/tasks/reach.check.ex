defmodule Mix.Tasks.Reach.Check do
  @moduledoc """
  Runs structural validation and change-safety checks.

      mix reach.check
      mix reach.check --arch
      mix reach.check --changed --base main
      mix reach.check --dead-code
      mix reach.check --smells
      mix reach.check --candidates

  ## Options

    * `--format` — output format: `text` or `json`
    * `--arch` — check `.reach.exs` architecture policy
    * `--changed` — report changed functions and configured test hints
    * `--base` — git base ref for `--changed` (default: auto-detect `main`, `master`, or upstream)
    * `--dead-code` — find unused pure expressions
    * `--smells` — find graph/effect/data-flow performance smells
    * `--candidates` — emit advisory refactoring candidates
    * `--top` — limit candidate output for `--candidates`

  """

  use Mix.Task

  alias Reach.CLI.Commands.Check
  alias Reach.CLI.Options
  alias Reach.CLI.Pipe

  @shortdoc "Structural validation and change-safety checks"

  @switches [
    format: :string,
    arch: :boolean,
    changed: :boolean,
    base: :string,
    dead_code: :boolean,
    smells: :boolean,
    candidates: :boolean,
    path: :string,
    top: :integer
  ]

  @aliases [f: :format]

  @impl Mix.Task
  def run(args) do
    Pipe.safely(fn ->
      {opts, positional} = Options.parse(args, @switches, @aliases)
      Check.run(opts, positional)
    end)
  end
end
