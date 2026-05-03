defmodule Reach.CLI.Commands.Trace.Slice do
  @moduledoc """
  Program slicing — finds the minimum set of statements that affect a value.

      mix reach.trace lib/my_app/user_controller.ex:18
      mix reach.trace MyApp.UserService.create/1 --variable changeset
      mix reach.trace --forward lib/my_app/user_service.ex:30 --variable user
      mix reach.trace lib/my_app_web/controllers/user_controller.ex:18 --format json

  ## Options

    * `--forward` — forward slice (where does this value flow to?)
    * `--variable` — trace a specific variable name within the slice
    * `--format` — output format: `text` (default), `json`, `oneline`

  """

  @switches [format: :string, forward: :boolean, variable: :string, graph: :boolean]
  @aliases [f: :format]

  alias Reach.CLI.BoxartGraph
  alias Reach.CLI.Format
  alias Reach.CLI.Options
  alias Reach.CLI.Project
  alias Reach.Project.Query
  alias Reach.Trace.Slice

  @default_statement_limit 30

  def run(args, cli_opts \\ []) do
    {opts, target_args} = Options.parse(args, @switches, @aliases)

    raw_target =
      List.first(target_args) ||
        Mix.raise(
          "Expected a target. Usage:\n" <>
            "  mix reach.trace lib/foo.ex:42\n" <>
            "  mix reach.trace Module.function/arity"
        )

    run_target(raw_target, opts, cli_opts)
  end

  def run_target(raw_target, opts, cli_opts \\ []) do
    project = Project.load(quiet: opts[:format] == "json")
    format = opts[:format] || "text"
    forward? = Keyword.get(opts, :forward, false)
    var_name = opts[:variable]

    {node, target} = resolve_slice_target(project, raw_target)

    result =
      Slice.compute(project, node,
        forward: forward?,
        variable: var_name,
        limit: statement_limit(opts)
      )

    if opts[:graph] do
      BoxartGraph.require!()
      BoxartGraph.render_slice_graph(project, node.id, forward?)
    else
      render(format, result, target, cli_opts)
    end
  end

  defp resolve_slice_target(project, raw) do
    case Project.parse_file_line(raw) do
      {file, line} ->
        n = Slice.find_node_at_location(project, file, line)
        unless n, do: Mix.raise("No node found at #{file}:#{line}")
        {n, %{file: file, line: line}}

      nil ->
        mfa = Query.resolve_target(project, raw)
        unless mfa, do: Mix.raise("Function not found: #{raw}")

        func_node = Query.find_function(project, mfa)
        unless func_node, do: Mix.raise("Function definition not found in IR: #{raw}")

        span = func_node.source_span
        {func_node, %{file: span[:file], line: span[:start_line]}}
    end
  end

  defp render("json", result, target, cli_opts) do
    Format.render(
      %{
        target: %{file: target.file, line: target.line, node_id: result.node.id},
        direction: to_string(result.direction),
        statements: result.statements
      },
      command(cli_opts),
      format: "json",
      pretty: true
    )
  end

  defp render("oneline", result, _target, _cli_opts) do
    Enum.each(result.statements, fn stmt ->
      IO.puts("#{stmt.file}:#{stmt.line}: #{stmt.description}")
    end)
  end

  defp render(_format, result, _target, _cli_opts) do
    render_text(result)
  end

  defp command(cli_opts), do: Keyword.get(cli_opts, :command, "reach.trace")

  defp statement_limit(opts), do: Keyword.get(opts, :statement_limit, @default_statement_limit)

  defp render_text(result) do
    forward? = result.direction == :forward
    direction = if forward?, do: "Forward", else: "Backward"
    target_desc = Slice.describe_node(result.node)
    loc = Format.location(result.node)

    IO.puts(Format.header("#{direction} slice of #{target_desc} (#{loc})"))

    if result.statements == [] do
      hint = if forward?, do: "", else: " Try --forward to see where this value flows."
      IO.puts("No dependencies found.#{hint}")
    else
      Enum.each(result.statements, fn stmt ->
        IO.puts(
          "  #{Format.faint(Path.basename(stmt.file) <> ":" <> to_string(stmt.line))}  #{stmt.description}"
        )
      end)

      files = result.statements |> Enum.map(& &1.file) |> Enum.uniq() |> length()
      IO.puts("\n#{Format.count(length(result.statements))} statements, #{files} file(s)")
    end
  end
end
