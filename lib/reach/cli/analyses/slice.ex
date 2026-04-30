defmodule Reach.CLI.Analyses.Slice do
  @moduledoc """
  Program slicing — finds the minimum set of statements that affect a value.

      mix reach.slice lib/my_app/user_controller.ex:18
      mix reach.slice MyApp.UserService.create/1 --variable changeset
      mix reach.slice --forward lib/my_app/user_service.ex:30 --variable user
      mix reach.slice lib/my_app_web/controllers/user_controller.ex:18 --format json

  ## Options

    * `--forward` — forward slice (where does this value flow to?)
    * `--variable` — trace a specific variable name within the slice
    * `--format` — output format: `text` (default), `json`, `oneline`

  """

  @switches [format: :string, forward: :boolean, variable: :string, graph: :boolean]
  @aliases [f: :format]

  alias Reach.CLI.BoxartGraph
  alias Reach.CLI.Format
  alias Reach.CLI.Project

  def run(args) do
    {opts, target_args, _} = OptionParser.parse(args, switches: @switches, aliases: @aliases)

    unless target_args != [] do
      Mix.raise(
        "Expected a target. Usage:\n" <>
          "  mix reach.slice lib/foo.ex:42\n" <>
          "  mix reach.slice Module.function/arity"
      )
    end

    project = Project.load(quiet: opts[:format] == "json")
    format = opts[:format] || "text"
    forward? = Keyword.get(opts, :forward, false)
    var_name = opts[:variable]

    {node, target} = resolve_slice_target(project, hd(target_args))

    slice_ids = compute_slice(project.graph, node.id, forward?)
    result = filter_and_format(project, slice_ids, var_name)

    if opts[:graph] do
      BoxartGraph.require!()
      BoxartGraph.render_slice_graph(project, node.id, forward?)
    else
      render(format, node, result, forward?, target)
    end
  end

  defp resolve_slice_target(project, raw) do
    case Project.parse_file_line(raw) do
      {file, line} ->
        n = find_node_at_location(project, file, line)
        unless n, do: Mix.raise("No node found at #{file}:#{line}")
        {n, %{file: file, line: line}}

      nil ->
        mfa = Project.resolve_target(project, raw)
        unless mfa, do: Mix.raise("Function not found: #{raw}")

        func_node = Project.find_function(project, mfa)
        unless func_node, do: Mix.raise("Function definition not found in IR: #{raw}")

        span = func_node.source_span
        {func_node, %{file: span[:file], line: span[:start_line]}}
    end
  end

  defp compute_slice(graph, node_id, forward?) do
    if Graph.has_vertex?(graph, node_id) do
      if forward? do
        Graph.reachable(graph, [node_id]) -- [node_id]
      else
        Graph.reaching(graph, [node_id]) -- [node_id]
      end
    else
      []
    end
  end

  defp render("json", node, result, forward?, target) do
    Format.render(
      %{
        target: %{file: target.file, line: target.line, node_id: node.id},
        direction: if(forward?, do: "forward", else: "backward"),
        statements: result
      },
      "reach.slice",
      format: "json",
      pretty: true
    )
  end

  defp render("oneline", _node, result, _forward?, _target) do
    Enum.each(result, fn stmt ->
      IO.puts("#{stmt.file}:#{stmt.line}: #{stmt.description}")
    end)
  end

  defp render(_format, node, result, forward?, _target) do
    render_text(node, result, forward?)
  end

  defp find_node_at_location(project, file, line) do
    target_basename = Path.basename(file)

    Map.values(project.nodes)
    |> Enum.filter(fn n ->
      case n.source_span do
        %{file: f, start_line: l} ->
          Project.file_matches?(f, file) and l == line and
            not (f != file and f != target_basename)

        _ ->
          false
      end
    end)
    |> Enum.min_by(
      fn n -> node_specificity(n) end,
      fn -> nil end
    )
  end

  defp node_specificity(n) do
    case n.type do
      :var -> 0
      :call -> 1
      :literal -> 2
      :match -> 3
      :block -> 10
      :clause -> 11
      :function_def -> 12
      _ -> 5
    end
  end

  defp filter_and_format(project, slice_ids, var_name) do
    slice_ids
    |> Enum.map(fn id -> Map.get(project.nodes, id) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.filter(& &1.source_span)
    |> maybe_filter_variable(var_name)
    |> Enum.map(fn n ->
      %{
        file: n.source_span[:file],
        line: n.source_span[:start_line],
        description: describe_node(n),
        type: n.type
      }
    end)
    |> Enum.sort_by(fn stmt -> {stmt.file, stmt.line} end)
    |> Enum.uniq_by(fn stmt -> {stmt.file, stmt.line} end)
    |> Enum.take(30)
  end

  defp maybe_filter_variable(nodes, nil), do: nodes

  defp maybe_filter_variable(nodes, var_name) do
    Enum.filter(nodes, fn n ->
      case n.type do
        :var -> to_string(n.meta[:name]) == var_name
        :match -> true
        :call -> true
        _ -> false
      end
    end)
  end

  defp describe_node(node) do
    case node.type do
      :var ->
        "var #{node.meta[:name]}"

      :call ->
        mod = node.meta[:module]
        fun = node.meta[:function]
        if mod && fun, do: "#{inspect(mod)}.#{fun}", else: "call"

      :match ->
        "match"

      :literal ->
        inspect(node.meta[:value])

      other ->
        to_string(other)
    end
  end

  defp render_text(node, result, forward?) do
    direction = if forward?, do: "Forward", else: "Backward"
    target_desc = describe_node(node)
    loc = Format.location(node)

    IO.puts(Format.header("#{direction} slice of #{target_desc} (#{loc})"))

    if result == [] do
      hint = if forward?, do: "", else: " Try --forward to see where this value flows."
      IO.puts("No dependencies found.#{hint}")
    else
      Enum.each(result, fn stmt ->
        IO.puts(
          "  #{Format.faint(Path.basename(stmt.file) <> ":" <> to_string(stmt.line))}  #{stmt.description}"
        )
      end)

      files = result |> Enum.map(& &1.file) |> Enum.uniq() |> length()
      IO.puts("\n#{Format.count(length(result))} statements, #{files} file(s)")
    end
  end
end
