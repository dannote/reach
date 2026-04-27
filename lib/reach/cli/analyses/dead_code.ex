defmodule Reach.CLI.Analyses.DeadCode do
  @moduledoc """
  Finds dead code — pure expressions whose values are never used.

      mix reach.dead_code
      mix reach.dead_code lib/my_app/
      mix reach.dead_code --format json

  ## Options

    * `--format` — output format: `text` (default), `json`, `oneline`
    * `--path` — restrict analysis to specific path

  """

  alias Reach.CLI.Format

  @switches [format: :string, path: :string]
  @aliases [f: :format]

  def run(args) do
    {opts, args, _} = OptionParser.parse(args, switches: @switches, aliases: @aliases)
    format = opts[:format] || "text"

    Mix.Task.run("compile", ["--no-warnings-as-errors"])

    files = collect_files(opts[:path] || List.first(args))
    unless format == "json", do: Mix.shell().info("Analyzing #{length(files)} file(s)...")

    findings =
      files
      |> Task.async_stream(
        fn file ->
          case Reach.file_to_graph(file) do
            {:ok, graph} ->
              Reach.dead_code(graph)
              |> Enum.filter(& &1.source_span)
              |> Enum.map(&finding_from_node(&1, file))

            _ ->
              []
          end
        end,
        max_concurrency: System.schedulers_online(),
        ordered: false
      )
      |> Enum.flat_map(fn {:ok, results} -> results end)
      |> Enum.sort_by(&{&1.file, &1.line})
      |> Enum.uniq_by(&{&1.file, &1.line})

    case format do
      "json" ->
        Format.render(%{findings: findings}, "reach.dead_code", format: "json", pretty: true)

      "oneline" ->
        Enum.each(findings, fn f ->
          IO.puts(
            "#{Format.faint("#{f.file}:#{f.line}")}: #{Format.yellow(to_string(f.kind))}: #{f.description}"
          )
        end)

      _ ->
        render_text(findings)
    end
  end

  defp collect_files(nil) do
    Path.wildcard("lib/**/*.ex") ++ Path.wildcard("src/**/*.erl")
  end

  defp collect_files(path) do
    if File.dir?(path) do
      Path.wildcard(Path.join(path, "**/*.ex"))
    else
      [path]
    end
  end

  defp finding_from_node(node, file) do
    %{
      file: file,
      line: node.source_span.start_line,
      kind: node.type,
      description: describe(node)
    }
  end

  defp describe(node) do
    case node.type do
      :call ->
        mod = node.meta[:module]
        fun = node.meta[:function]
        if mod, do: "#{inspect(mod)}.#{fun} result unused", else: "#{fun} result unused"

      :binary_op ->
        "#{node.meta[:operator]} result unused"

      :unary_op ->
        "#{node.meta[:operator]} result unused"

      :match ->
        match_description(node)

      _ ->
        "#{node.type} unused"
    end
  end

  defp match_description(node) do
    case node.children do
      [%{type: :var, meta: %{name: name}}, %{type: :call} = rhs] ->
        mod = if rhs.meta[:module], do: inspect(rhs.meta[:module]) <> ".", else: ""
        "#{name} = #{mod}#{rhs.meta[:function]} is unused"

      [%{type: :var, meta: %{name: name}} | _] ->
        "#{name} = ... is unused"

      _ ->
        "match result unused"
    end
  end

  defp render_text([]) do
    IO.puts("  (none found)")
  end

  defp render_text(findings) do
    IO.puts(Format.header("Dead Code"))

    findings
    |> Enum.group_by(& &1.file)
    |> Enum.sort_by(fn {file, _} -> file end)
    |> Enum.each(fn {file, file_findings} ->
      IO.puts(Format.section(Format.faint(file)))

      Enum.each(file_findings, fn f ->
        IO.puts("  line #{Format.yellow(to_string(f.line))}: #{f.description}")
      end)
    end)

    IO.puts("\n#{Format.count(length(findings))} finding(s)\n")
  end
end
