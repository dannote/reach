defmodule Reach.CLI.Commands.OTP.Concurrency do
  @moduledoc """
  Concurrency patterns — Task.async/await pairing, process monitors,
  spawn_link chains, and supervisor topology.

      mix reach.otp --concurrency
      mix reach.otp --concurrency --format json

  ## Options

    * `--format` — output format: `text` (default), `json`, `oneline`

  """

  alias Reach.CLI.Options
  alias Reach.CLI.Project
  alias Reach.CLI.Render.OTP.Concurrency, as: ConcurrencyRender
  alias Reach.OTP.Concurrency

  @switches [format: :string]
  @aliases [f: :format]

  def run(args, cli_opts \\ []) do
    Options.run(args, @switches, @aliases, fn opts, _positional ->
      run_opts(opts, cli_opts)
    end)
  end

  def run_opts(opts, cli_opts \\ []) do
    format = opts[:format] || "text"

    project = Project.load(quiet: opts[:format] == "json")
    result = Concurrency.analyze(project)

    ConcurrencyRender.render(result, format, command(cli_opts))
  end

  defp command(cli_opts), do: Keyword.get(cli_opts, :command, "reach.otp")
end
