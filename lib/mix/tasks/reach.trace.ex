defmodule Mix.Tasks.Reach.Trace do
  @moduledoc """
  Traces data flow, taint paths, and forward/backward slices.

      mix reach.trace --from conn.params --to Repo
      mix reach.trace --from conn.params --to System.cmd
      mix reach.trace --variable user --in MyApp.Accounts.create/1
      mix reach.trace --backward lib/my_app/accounts.ex:45
      mix reach.trace --forward lib/my_app/accounts.ex:45

  ## Options

    * `--from` — taint source pattern
    * `--to` — sink pattern
    * `--variable` — trace a variable name
    * `--in` — restrict variable tracing to a function
    * `--backward` — compute a backward slice from a target
    * `--forward` — compute a forward slice from a target
    * `--format` — output format: `text`, `json`, `oneline`
    * `--graph` — render slice graph where supported
    * `--limit` — text display limit for paths/rows; also caps taint paths unless `--all` is set
    * `--all` — show all text rows/paths and collect all taint paths

  """

  use Mix.Task

  alias Reach.CLI.TaskRunner

  @shortdoc "Trace data flow, taint paths, and slices"

  @switches [
    format: :string,
    from: :string,
    to: :string,
    variable: :string,
    in: :string,
    backward: :string,
    forward: :string,
    graph: :boolean,
    limit: :integer,
    all: :boolean
  ]

  @aliases [f: :format]

  @impl Mix.Task
  def run(args) do
    {opts, positional, _} = OptionParser.parse(args, switches: @switches, aliases: @aliases)

    case trace_action(opts, positional) do
      :flow ->
        TaskRunner.run("reach.flow", flow_args(opts), command: "reach.trace")

      {:slice, target, direction} ->
        TaskRunner.run("reach.slice", slice_args(target, opts, direction), command: "reach.trace")

      :error ->
        Mix.raise("Provide --from/--to, --variable, --backward TARGET, or --forward TARGET")
    end
  end

  defp trace_action(opts, positional) do
    [
      {flow_trace?(opts, positional), :flow},
      {opts[:backward], {:slice, opts[:backward], forward?: false}},
      {opts[:forward], {:slice, opts[:forward], forward?: true}},
      {positional != [], {:slice, List.first(positional), forward?: false}}
    ]
    |> Enum.find_value(:error, fn
      {nil, _action} -> nil
      {false, _action} -> nil
      {_enabled, action} -> action
    end)
  end

  defp flow_trace?(opts, positional) do
    opts[:from] || opts[:to] || (opts[:variable] && opts[:in]) ||
      (opts[:variable] && positional == [])
  end

  defp flow_args(opts) do
    []
    |> maybe_put("--format", opts[:format])
    |> maybe_put("--from", opts[:from])
    |> maybe_put("--to", opts[:to])
    |> maybe_put("--variable", opts[:variable])
    |> maybe_put("--in", opts[:in])
    |> maybe_put("--limit", opts[:limit])
    |> maybe_flag("--all", opts[:all])
  end

  defp slice_args(target, opts, extra) do
    [target]
    |> maybe_put("--format", opts[:format])
    |> maybe_put("--variable", opts[:variable])
    |> maybe_flag("--forward", Keyword.fetch!(extra, :forward?))
    |> maybe_flag("--graph", opts[:graph])
  end

  defp maybe_put(args, _flag, nil), do: args
  defp maybe_put(args, flag, value), do: args ++ [flag, to_string(value)]

  defp maybe_flag(args, _flag, false), do: args
  defp maybe_flag(args, _flag, nil), do: args
  defp maybe_flag(args, flag, true), do: args ++ [flag]
end
