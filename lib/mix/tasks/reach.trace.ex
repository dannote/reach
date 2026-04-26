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
    graph: :boolean
  ]

  @aliases [f: :format]

  @impl Mix.Task
  def run(args) do
    {opts, positional, _} = OptionParser.parse(args, switches: @switches, aliases: @aliases)

    cond do
      opts[:from] || opts[:to] || (opts[:variable] && opts[:in]) ||
          (opts[:variable] && positional == []) ->
        TaskRunner.run("reach.flow", flow_args(opts))

      opts[:backward] ->
        TaskRunner.run("reach.slice", slice_args(opts[:backward], opts, forward?: false))

      opts[:forward] ->
        TaskRunner.run("reach.slice", slice_args(opts[:forward], opts, forward?: true))

      positional != [] ->
        TaskRunner.run("reach.slice", slice_args(List.first(positional), opts, forward?: false))

      true ->
        Mix.raise("Provide --from/--to, --variable, --backward TARGET, or --forward TARGET")
    end
  end

  defp flow_args(opts) do
    []
    |> maybe_put("--format", opts[:format])
    |> maybe_put("--from", opts[:from])
    |> maybe_put("--to", opts[:to])
    |> maybe_put("--variable", opts[:variable])
    |> maybe_put("--in", opts[:in])
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
