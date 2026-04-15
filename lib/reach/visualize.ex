defmodule Reach.Visualize do
  @moduledoc false

  alias Reach.Visualize.ControlFlow

  # ── Public API ──

  def to_graph_json(graph, opts \\ []) do
    %{
      control_flow: control_flow_data(graph),
      call_graph: call_graph_data(graph),
      data_flow: data_flow_data(graph, opts)
    }
  end

  def to_json(graph, opts \\ []) do
    unless Code.ensure_loaded?(Jason) do
      raise "Jason is required. Add {:jason, \"~> 1.0\"} to your deps."
    end

    graph |> to_graph_json(opts) |> Jason.encode!()
  end

  def makeup_stylesheet do
    if Code.ensure_loaded?(Makeup) do
      Makeup.stylesheet()
    else
      ""
    end
  end

  # ── Control Flow ──

  defp control_flow_data(graph) do
    all_nodes = Reach.nodes(graph)
    ControlFlow.build(all_nodes, graph)
  end

  # ── Call Graph ──

  defp call_graph_data(graph) do
    all_nodes = Reach.nodes(graph)
    call_graph = extract_call_graph(graph)

    modules =
      all_nodes
      |> Enum.filter(&(&1.type == :module_def))
      |> Enum.map(fn mod ->
        funcs =
          Reach.IR.all_nodes(mod)
          |> Enum.filter(&(&1.type == :function_def))
          |> Enum.map(fn f ->
            %{
              id: call_id(mod.meta[:name], f.meta[:name], f.meta[:arity]),
              name: to_string(f.meta[:name]),
              arity: f.meta[:arity] || 0
            }
          end)

        %{
          id: inspect(mod.meta[:name]),
          name: inspect(mod.meta[:name]),
          file: get_in(mod, [Access.key(:source_span), Access.key(:file)]),
          functions: funcs
        }
      end)

    edges =
      Graph.edges(call_graph)
      |> Enum.map(fn e ->
        {src_mod, src_fn, src_ar} = e.v1
        {tgt_mod, tgt_fn, tgt_ar} = e.v2

        %{
          id: "call_#{call_id(src_mod, src_fn, src_ar)}_#{call_id(tgt_mod, tgt_fn, tgt_ar)}",
          source: call_id(src_mod, src_fn, src_ar),
          target: call_id(tgt_mod, tgt_fn, tgt_ar),
          color: "#7c3aed"
        }
      end)
      |> Enum.uniq_by(& &1.id)

    # Collect external modules referenced by edges
    internal_ids =
      modules
      |> Enum.flat_map(fn m -> Enum.map(m.functions, & &1.id) end)
      |> MapSet.new()

    external_ids =
      edges
      |> Enum.flat_map(fn e -> [e.source, e.target] end)
      |> Enum.reject(&(&1 in internal_ids))
      |> Enum.uniq()
      |> Enum.map(fn id ->
        %{id: id, name: id, arity: 0}
      end)

    external_by_module =
      external_ids
      |> Enum.group_by(fn %{name: name} ->
        name |> String.split(".") |> Enum.slice(0..-2//1) |> Enum.join(".")
      end)
      |> Enum.map(fn {mod_name, funcs} ->
        %{id: mod_name, name: mod_name, file: nil, functions: funcs}
      end)

    %{modules: modules ++ external_by_module, edges: edges}
  end

  defp call_id(mod, func, arity) do
    mod_str = if mod, do: inspect(mod), else: "_"
    "#{mod_str}.#{func}/#{arity}"
  end

  defp extract_call_graph(%Reach.Project{call_graph: cg}), do: cg
  defp extract_call_graph(%Reach.SystemDependence{call_graph: cg}), do: cg

  # ── Data Flow ──

  defp data_flow_data(graph, opts) do
    taint_results =
      case Keyword.get(opts, :taint) do
        nil -> []
        taint_opts -> Reach.taint_analysis(graph, taint_opts)
      end

    all_nodes = Reach.nodes(graph)
    func_nodes = Enum.filter(all_nodes, &(&1.type == :function_def))
    node_to_func = build_node_to_func_map(all_nodes, func_nodes)

    raw_edges =
      graph
      |> Reach.edges()
      |> Enum.filter(fn e ->
        is_integer(e.v1) and is_integer(e.v2) and
          match?({:data, _}, e.label)
      end)

    func_edges =
      raw_edges
      |> Enum.map(fn e ->
        src = Map.get(node_to_func, e.v1, e.v1)
        tgt = Map.get(node_to_func, e.v2, e.v2)
        {_, var} = e.label
        %{src: src, tgt: tgt, var: var}
      end)
      |> Enum.reject(&(&1.src == &1.tgt))
      |> Enum.uniq_by(fn e -> {e.src, e.tgt} end)

    functions =
      func_nodes
      |> Enum.filter(fn f -> Enum.any?(func_edges, &(&1.src == f.id or &1.tgt == f.id)) end)
      |> Enum.map(fn f ->
        source = extract_func_source(f)
        start_line = get_in(f, [Access.key(:source_span), Access.key(:start_line)]) || 1

        %{
          id: to_string(f.id),
          label: "#{f.meta[:name]}/#{f.meta[:arity]}",
          module: f.meta[:module] && inspect(f.meta[:module]),
          start_line: start_line,
          source_html: highlight_source(source)
        }
      end)

    edges =
      func_edges
      |> Enum.map(fn e ->
        %{
          id: "df_#{e.src}_#{e.tgt}",
          source: to_string(e.src),
          target: to_string(e.tgt),
          label: to_string(e.var),
          color: "#16a34a"
        }
      end)

    taint_paths =
      Enum.map(taint_results, fn result ->
        %{
          source: node_label_short(result.source),
          sink: node_label_short(result.sink),
          path: Enum.map(result.path, &node_label_short/1)
        }
      end)

    %{functions: functions, edges: edges, taint_paths: taint_paths}
  end

  # ── Helpers ──

  defp build_node_to_func_map(_all_nodes, func_nodes) do
    func_ids = MapSet.new(func_nodes, & &1.id)

    for func <- func_nodes,
        child <- Reach.IR.all_nodes(func),
        child.id not in func_ids,
        into: %{} do
      {child.id, func.id}
    end
  end

  def extract_func_source(%{type: :function_def, source_span: %{file: file, start_line: start}})
      when is_binary(file) and is_integer(start) do
    with {:ok, content} <- File.read(file),
         end_line when is_integer(end_line) <- find_end_line(file, start) do
      content
      |> String.split("\n")
      |> Enum.slice((start - 1)..(end_line - 1))
      |> Enum.join("\n")
      |> format_source()
    else
      _ -> nil
    end
  end

  def extract_func_source(_), do: nil

  defp format_source(source) do
    Code.format_string!(source) |> IO.iodata_to_binary()
  rescue
    _ -> String.trim(source)
  end

  @def_end_cache_key :reach_def_end_cache

  defp find_end_line(file, start_line) do
    cache = Process.get(@def_end_cache_key, %{})

    case Map.get(cache, file) do
      nil ->
        line_map = build_def_line_map(file)
        Process.put(@def_end_cache_key, Map.put(cache, file, line_map))
        Map.get(line_map, start_line)

      line_map ->
        Map.get(line_map, start_line)
    end
  end

  defp build_def_line_map(file) do
    with {:ok, source} <- File.read(file),
         {:ok, ast} <-
           Code.string_to_quoted(source,
             columns: true,
             token_metadata: true,
             file: file
           ) do
      collect_def_ranges(ast)
    else
      _ -> %{}
    end
  end

  defp collect_def_ranges(ast) do
    {_, ranges} =
      Macro.prewalk(ast, %{}, fn
        {def_type, meta, [{_name, _, _} | _]} = node, acc
        when def_type in [:def, :defp, :defmacro, :defmacrop] ->
          end_meta = meta[:end]

          end_line =
            if end_meta, do: end_meta[:line], else: meta[:line]

          {node, Map.put(acc, meta[:line], end_line)}

        node, acc ->
          {node, acc}
      end)

    ranges
  end

  defp highlight_source(nil), do: nil

  defp highlight_source(source) do
    if Code.ensure_loaded?(Makeup) do
      source |> Makeup.highlight() |> strip_pre_wrapper()
    else
      nil
    end
  end

  defp strip_pre_wrapper(html) do
    html
    |> String.replace(~r{^<pre class="highlight"><code>}, "")
    |> String.replace(~r{</code></pre>$}, "")
  end

  defp node_label_short(%{type: :call, meta: meta}) do
    case meta[:module] do
      nil -> "#{meta[:function]}/#{meta[:arity]}"
      mod -> "#{inspect(mod)}.#{meta[:function]}/#{meta[:arity]}"
    end
  end

  defp node_label_short(%{meta: %{name: name}}), do: to_string(name)
  defp node_label_short(%{type: type}), do: to_string(type)
end
