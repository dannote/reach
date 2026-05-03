defmodule Reach.Check.DeadCode do
  @moduledoc """
  Finds dead code — pure expressions whose values are never used.
  """

  def collect_files(nil) do
    Path.wildcard("lib/**/*.ex") ++ Path.wildcard("src/**/*.erl")
  end

  def collect_files(path) do
    if File.dir?(path) do
      Path.wildcard(Path.join(path, "**/*.ex"))
    else
      [path]
    end
  end

  def run(files) do
    files
    |> Task.async_stream(&find_in_file/1,
      max_concurrency: System.schedulers_online(),
      ordered: false
    )
    |> Enum.flat_map(fn {:ok, results} -> results end)
    |> Enum.sort_by(&{&1.file, &1.line})
    |> Enum.uniq_by(&{&1.file, &1.line})
  end

  defp find_in_file(file) do
    case Reach.file_to_graph(file) do
      {:ok, graph} ->
        graph
        |> Reach.dead_code()
        |> Enum.filter(& &1.source_span)
        |> Enum.map(&finding_from_node(&1, file))

      _ ->
        []
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
end
