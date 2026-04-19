defmodule Mix.Tasks.Reach.Xref do
  @moduledoc """
  Cross-function data flow — shows how data moves between functions
  through the system dependence graph.

  For each function, reports which variables flow in from callers
  (parameter edges) and which flow out to callees (summary/return edges).

      mix reach.xref
      mix reach.xref --format json
      mix reach.xref --top 10

  ## Options

    * `--format` — output format: `text` (default), `json`, `oneline`
    * `--top` — show top N functions by cross-function edge count (default: 20)

  """

  use Mix.Task

  alias Reach.CLI.Format
  alias Reach.CLI.Project
  alias Reach.IR

  @shortdoc "Cross-function data flow"

  @switches [format: :string, top: :integer]
  @aliases [f: :format]

  @cross_labels [
    :parameter_in,
    :parameter_out,
    :call,
    :summary,
    :state_pass,
    :state_read,
    :call_reply
  ]

  @impl Mix.Task
  def run(args) do
    {opts, _args, _} = OptionParser.parse(args, switches: @switches, aliases: @aliases)
    format = opts[:format] || "text"
    top = opts[:top] || 20

    project = Project.load()
    result = analyze(project, top)

    case format do
      "json" -> Format.render(%{functions: result}, "reach.xref", format: "json", pretty: true)
      "oneline" -> render_oneline(result)
      _ -> render_text(result)
    end
  end

  defp analyze(project, top) do
    edges = Graph.edges(project.graph)
    nodes = project.nodes
    all_nodes = Map.values(nodes)
    mod_defs = Enum.filter(all_nodes, &(&1.type == :module_def))

    func_index = build_func_index(mod_defs)

    cross_edges =
      edges
      |> Enum.filter(&cross_function_edge?/1)
      |> Enum.flat_map(fn edge ->
        source_func = Map.get(func_index, edge.v1)
        target_func = Map.get(func_index, edge.v2)
        source_node = Map.get(nodes, edge.v1)
        target_node = Map.get(nodes, edge.v2)

        if source_func && target_func && source_func != target_func do
          [
            %{
              from_func: source_func,
              to_func: target_func,
              label: normalize_label(edge.label),
              from_node: node_summary(source_node),
              to_node: node_summary(target_node)
            }
          ]
        else
          []
        end
      end)

    cross_edges
    |> Enum.group_by(&{&1.from_func, &1.to_func})
    |> Enum.map(fn {{from, to}, edges} ->
      labels = edges |> Enum.map(& &1.label) |> Enum.frequencies()

      vars =
        edges
        |> Enum.flat_map(fn e -> [e.from_node, e.to_node] end)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
        |> Enum.take(5)

      %{
        from: func_string(from),
        to: func_string(to),
        edges: Enum.sum(Map.values(labels)),
        labels: labels,
        variables: vars
      }
    end)
    |> Enum.sort_by(& &1.edges, :desc)
    |> Enum.take(top)
  end

  defp build_func_index(mod_defs) do
    Enum.reduce(mod_defs, %{}, fn m, acc ->
      mod_name = m.meta[:name]
      funcs = m |> IR.all_nodes() |> Enum.filter(&(&1.type == :function_def))

      Enum.reduce(funcs, acc, fn f, inner ->
        func_id = {mod_name, f.meta[:name], f.meta[:arity]}

        f
        |> IR.all_nodes()
        |> Enum.reduce(inner, fn node, a -> Map.put_new(a, node.id, func_id) end)
      end)
    end)
  end

  defp cross_function_edge?(%{label: label}) do
    normalized = normalize_label(label)
    normalized in @cross_labels
  end

  defp normalize_label({label, _}), do: label
  defp normalize_label(label), do: label

  defp node_summary(nil), do: nil
  defp node_summary(%{type: :var, meta: %{name: name}}), do: to_string(name)
  defp node_summary(%{type: :call, meta: %{function: f}}), do: to_string(f)
  defp node_summary(%{type: :literal, meta: %{value: v}}), do: inspect(v)
  defp node_summary(%{type: type}), do: to_string(type)

  defp func_string({mod, fun, arity}) when mod != nil, do: "#{inspect(mod)}.#{fun}/#{arity}"
  defp func_string({nil, fun, arity}), do: "#{fun}/#{arity}"

  # --- Rendering ---

  defp render_text(result) do
    IO.puts(Format.header("Cross-Function Data Flow (#{length(result)})"))

    if result == [] do
      IO.puts("  (no cross-function data flow detected)\n")
    else
      Enum.each(result, fn r ->
        IO.puts("  #{Format.bright(r.from)} → #{Format.bright(r.to)}")

        labels_str = r.labels |> Enum.map(fn {l, c} -> "#{l}×#{c}" end) |> Enum.join(", ")
        IO.puts("    #{r.edges} edges: #{Format.faint(labels_str)}")

        if r.variables != [] do
          IO.puts("    via: #{Format.cyan(Enum.join(r.variables, ", "))}")
        end
      end)

      IO.puts("\n#{Format.count(length(result))} connection(s)\n")
    end
  end

  defp render_oneline(result) do
    Enum.each(result, fn r ->
      labels_str = r.labels |> Enum.map(fn {l, c} -> "#{l}×#{c}" end) |> Enum.join(",")
      IO.puts("#{r.from}\t#{r.to}\t#{r.edges}\t#{labels_str}")
    end)
  end
end
