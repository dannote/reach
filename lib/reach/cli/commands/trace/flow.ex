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

  alias Reach.CLI.Format
  alias Reach.CLI.Options
  alias Reach.CLI.Project
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

    project = Project.load(quiet: opts[:format] == "json")

    result =
      cond do
        opts[:from] && opts[:to] ->
          Flow.analyze_taint(project, opts[:from], opts[:to], path_limit(opts))

        opts[:variable] ->
          Flow.analyze_variable(project, opts[:variable], opts[:in])

        true ->
          Mix.raise("Provide --from/--to for taint analysis or --variable for data tracing")
      end

    case format do
      "json" -> Format.render(result, command(cli_opts), format: "json", pretty: true)
      "oneline" -> render_oneline(result)
      _ -> render_text(project, result, display_limit(opts))
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

  defp render_text(project, result, limit) do
    case result.type do
      :taint -> render_taint_text(project, result, limit)
      :variable -> render_variable_text(result, limit)
    end
  end

  defp render_taint_text(_project, result, limit) do
    IO.puts(Format.header("Taint: #{result.from} → #{result.to}"))

    if result.paths == [] do
      IO.puts("\n  " <> Format.empty("no data flow paths") <> "\n")
    else
      shown = take_limited(result.paths, limit)
      IO.puts("#{length(result.paths)} path(s) found. Showing #{length(shown)}.\n")
      shown |> Enum.with_index() |> Enum.each(&print_path/1)
      render_omitted_hint(length(result.paths) - length(shown), "path(s)")
    end
  end

  defp print_path({path, idx}) do
    IO.puts("Path #{idx + 1}:")
    IO.puts("  #{fmt_node(path.source)}")
    Enum.each(path.intermediate, fn node -> IO.puts("  #{fmt_node(node)}") end)
    IO.puts("  #{fmt_node(path.sink)}")
    IO.puts("")
  end

  defp render_variable_text(result, limit) do
    IO.puts(Format.header("Variable: #{result.variable}"))
    IO.puts("  definitions=#{length(result.definitions)} uses=#{length(result.uses)}")

    IO.puts(Format.section("Definitions"))
    render_limited_nodes(result.definitions, limit)

    IO.puts(Format.section("Uses"))
    render_limited_nodes(result.uses, limit)
  end

  defp render_limited_nodes([], _limit), do: IO.puts("  " <> Format.empty())

  defp render_limited_nodes(nodes, limit) do
    shown = take_limited(nodes, limit)
    Enum.each(shown, fn node -> IO.puts("  #{fmt_node(node)}") end)

    render_omitted_hint(length(nodes) - length(shown), "more")
  end

  defp take_limited(items, :all), do: items
  defp take_limited(items, limit), do: Enum.take(items, limit)

  defp render_omitted_hint(remaining, _label) when remaining <= 0, do: :ok

  defp render_omitted_hint(remaining, label) do
    IO.puts(
      "  " <>
        Format.omitted("#{remaining} #{label} omitted. Use --limit N, --all, or --format json.")
    )
  end

  defp fmt_node(node) do
    loc = Format.location(node)

    desc =
      case node.type do
        :var -> "var #{node.meta[:name]}"
        :call -> Format.call_name(node)
        other -> to_string(other)
      end

    "#{loc}  #{desc}"
  end

  defp render_oneline(result) do
    case result.type do
      :taint ->
        Enum.each(result.paths, fn path ->
          src = Format.location(path.source)
          snk = Format.location(path.sink)
          IO.puts("#{src} → #{snk}")
        end)

      :variable ->
        Enum.each(result.definitions, fn node ->
          IO.puts("def:#{Format.location(node)}:#{result.variable}")
        end)

        Enum.each(result.uses, fn node ->
          IO.puts("use:#{Format.location(node)}:#{result.variable}")
        end)
    end
  end
end
