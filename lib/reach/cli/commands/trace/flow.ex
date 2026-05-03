defmodule Reach.CLI.Commands.Trace.Flow do
  @moduledoc """
  Traces data flow from sources to sinks. Detects taint paths where
  untrusted input reaches dangerous operations.

      mix reach.trace --from conn.params --to Repo
      mix reach.trace --variable user --in UserService.register/2
      mix reach.trace --from conn.params --to System.cmd --format json

  ## Options

    * `--from` — taint source pattern (e.g. `conn.params`, `params`)
    * `--to` — sink pattern (e.g. `Repo`, `System.cmd`)
    * `--variable` — trace a specific variable name
    * `--in` — restrict to a specific function
    * `--format` — output format: `text` (default), `json`, `oneline`
    * `--limit` — text display limit; also caps taint paths unless `--all` is set
    * `--all` — show all text rows/paths and collect all taint paths

  """

  @switches [
    format: :string,
    from: :string,
    to: :string,
    variable: :string,
    in: :string,
    limit: :integer,
    all: :boolean
  ]

  @aliases [f: :format]

  alias Reach.CLI.Options
  alias Reach.CLI.Project
  alias Reach.CLI.Render.Trace.Flow, as: FlowRender
  alias Reach.Trace.Flow

  @default_path_limit 50
  @default_display_limit 30

  def run(args, cli_opts \\ []) do
    Options.run(args, @switches, @aliases, fn opts, _positional ->
      run_opts(opts, cli_opts)
    end)
  end

  def run_opts(opts, cli_opts \\ []) do
    format = opts[:format] || "text"

    project = Project.load(quiet: format == "json")
    result = analyze(project, opts)

    FlowRender.render(result, format, display_limit(opts), command(cli_opts))
  end

  defp analyze(project, opts) do
    cond do
      opts[:from] && opts[:to] ->
        Flow.analyze_taint(project, opts[:from], opts[:to], path_limit(opts))

      opts[:variable] ->
        Flow.analyze_variable(project, opts[:variable], opts[:in])

      true ->
        Mix.raise("Provide --from/--to for taint analysis or --variable for data tracing")
    end
  end

  defp command(cli_opts), do: Keyword.get(cli_opts, :command, "reach.trace")

  defp path_limit(opts) do
    cond do
      opts[:all] -> :all
      is_integer(opts[:limit]) and opts[:limit] > @default_path_limit -> opts[:limit]
      true -> @default_path_limit
    end
  end

  defp display_limit(opts) do
    cond do
      opts[:all] -> :all
      is_integer(opts[:limit]) and opts[:limit] > 0 -> opts[:limit]
      true -> @default_display_limit
    end
  end
end
