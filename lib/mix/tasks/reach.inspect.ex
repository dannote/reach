defmodule Mix.Tasks.Reach.Inspect do
  @moduledoc """
  Explains one function, module, file, or line.

      mix reach.inspect Reach.Frontend.Elixir.translate/3
      mix reach.inspect lib/reach/frontend/elixir.ex:54
      mix reach.inspect TARGET --deps
      mix reach.inspect TARGET --impact
      mix reach.inspect TARGET --slice
      mix reach.inspect TARGET --graph
      mix reach.inspect TARGET --data
      mix reach.inspect TARGET --context
      mix reach.inspect TARGET --candidates

  ## Options

    * `--format` — output format passed to delegated analyses: `text`, `json`, `oneline`
    * `--deps` — callers, callees, and shared state
    * `--impact` — direct/transitive change impact
    * `--slice` — backward program slice
    * `--forward` — use a forward slice with `--slice` or `--data`
    * `--graph` — render graph output where supported
    * `--data` — target-local data-flow view, currently implemented as a slice view
    * `--context` — agent-readable bundle: deps plus impact
    * `--candidates` — advisory placeholder for graph-backed refactoring candidates
    * `--depth` — transitive depth passed to deps/impact
    * `--variable` — variable filter passed to slice

  """

  use Mix.Task

  alias Reach.CLI.TaskRunner

  @shortdoc "Inspect one target's dependencies, impact, slices, and context"

  @switches [
    format: :string,
    deps: :boolean,
    impact: :boolean,
    slice: :boolean,
    forward: :boolean,
    graph: :boolean,
    data: :boolean,
    context: :boolean,
    candidates: :boolean,
    depth: :integer,
    variable: :string
  ]

  @aliases [f: :format]

  @impl Mix.Task
  def run(args) do
    {opts, target_args, _} = OptionParser.parse(args, switches: @switches, aliases: @aliases)

    target =
      List.first(target_args) || Mix.raise("Expected a target. Usage: mix reach.inspect TARGET")

    cond do
      opts[:context] ->
        run_context(target, opts)

      opts[:candidates] ->
        render_candidates_placeholder(target, opts)

      opts[:impact] ->
        TaskRunner.run("reach.impact", target_args(target, opts, graph?: opts[:graph]))

      opts[:deps] or opts[:graph] ->
        TaskRunner.run("reach.deps", target_args(target, opts, graph?: opts[:graph]))

      opts[:slice] or opts[:data] ->
        TaskRunner.run("reach.slice", slice_args(target, opts))

      true ->
        run_context(target, opts)
    end
  end

  defp run_context(target, opts) do
    if opts[:format] == "json" do
      Mix.shell().info("Context JSON is not consolidated yet; emitting deps followed by impact.")
    else
      IO.puts("# Reach context for #{target}\n")
      IO.puts("## Dependencies\n")
    end

    TaskRunner.run("reach.deps", target_args(target, opts))

    unless opts[:format] == "json" do
      IO.puts("\n## Impact\n")
    end

    TaskRunner.run("reach.impact", target_args(target, opts))
  end

  defp render_candidates_placeholder(target, opts) do
    case opts[:format] do
      "json" ->
        ensure_json_encoder!()

        IO.puts(
          Jason.encode!(
            %{
              command: "reach.inspect",
              target: target,
              candidates: [],
              note: "Graph-backed refactoring candidates are planned for a later phase."
            },
            pretty: true
          )
        )

      _ ->
        IO.puts("Refactoring candidates for #{target}")
        IO.puts("")
        IO.puts("No automatic candidates are emitted yet.")

        IO.puts(
          "Planned candidate kinds: extract pure region, isolate effects, break cycles, move across layers, introduce boundary."
        )
    end
  end

  defp target_args(target, opts, extra \\ []) do
    [target]
    |> maybe_put("--format", opts[:format])
    |> maybe_put("--depth", opts[:depth])
    |> maybe_flag("--graph", Keyword.get(extra, :graph?, false))
  end

  defp slice_args(target, opts) do
    [target]
    |> maybe_put("--format", opts[:format])
    |> maybe_put("--variable", opts[:variable])
    |> maybe_flag("--forward", opts[:forward])
    |> maybe_flag("--graph", opts[:graph])
  end

  defp maybe_put(args, _flag, nil), do: args
  defp maybe_put(args, flag, value), do: args ++ [flag, to_string(value)]

  defp maybe_flag(args, _flag, false), do: args
  defp maybe_flag(args, _flag, nil), do: args
  defp maybe_flag(args, flag, true), do: args ++ [flag]

  defp ensure_json_encoder! do
    unless Code.ensure_loaded?(Jason) do
      Mix.raise("Jason is required for JSON output. Add {:jason, \"~> 1.0\"} to your deps.")
    end
  end
end
