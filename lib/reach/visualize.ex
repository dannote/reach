defmodule Reach.Visualize do
  @moduledoc false

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

    modules =
      all_nodes
      |> Enum.filter(&(&1.type == :module_def))
      |> Enum.map(fn mod ->
        func_nodes =
          Reach.IR.all_nodes(mod)
          |> Enum.filter(&(&1.type == :function_def))

        functions =
          Enum.map(func_nodes, fn func ->
            blocks = build_control_flow_blocks(func, graph)

            %{
              id: to_string(func.id),
              name: to_string(func.meta[:name]),
              arity: func.meta[:arity] || 0,
              blocks: blocks
            }
          end)

        %{
          module: inspect(mod.meta[:name]),
          file: get_in(mod, [Access.key(:source_span), Access.key(:file)]),
          functions: functions
        }
      end)

    # Handle top-level functions without module_def
    top_funcs =
      all_nodes
      |> Enum.filter(&(&1.type == :function_def))
      |> Enum.reject(fn func ->
        Enum.any?(modules, fn m ->
          Enum.any?(m.functions, &(&1.id == to_string(func.id)))
        end)
      end)

    if top_funcs != [] do
      top_module = %{
        module: nil,
        file: detect_file(top_funcs),
        functions:
          Enum.map(top_funcs, fn func ->
            %{
              id: to_string(func.id),
              name: to_string(func.meta[:name]),
              arity: func.meta[:arity] || 0,
              blocks: build_control_flow_blocks(func, graph)
            }
          end)
      }

      [top_module | modules]
    else
      modules
    end
  end

  defp build_control_flow_blocks(func, graph) do
    all_func_nodes = Reach.IR.all_nodes(func)

    control_edges =
      Reach.edges(graph)
      |> Enum.filter(fn e ->
        is_integer(e.v1) and is_integer(e.v2) and
          match?({:control, _}, e.label)
      end)

    func_node_ids = MapSet.new(all_func_nodes, & &1.id)

    branch_edges =
      control_edges
      |> Enum.filter(fn e -> e.v1 in func_node_ids and e.v2 in func_node_ids end)
      |> Enum.map(fn e ->
        {_, detail} = e.label

        %{
          id: "cfe_#{e.v1}_#{e.v2}",
          source: to_string(e.v1),
          target: to_string(e.v2),
          label: format_control_label(detail),
          color: branch_color(detail)
        }
      end)

    source = extract_source(func)
    html = highlight_source(source)
    start_line = get_in(func, [Access.key(:source_span), Access.key(:start_line)]) || 1

    entry_block = %{
      id: to_string(func.id),
      label: "#{func.meta[:name]}/#{func.meta[:arity]}",
      start_line: start_line,
      lines: if(source, do: String.split(source, "\n"), else: []),
      source_html: html
    }

    # Find nodes that are branch targets
    branch_target_ids = MapSet.new(branch_edges, & &1.target)

    target_blocks =
      all_func_nodes
      |> Enum.filter(&(to_string(&1.id) in branch_target_ids))
      |> Enum.map(fn node ->
        node_source = extract_node_source(node)
        node_html = highlight_source(node_source)

        node_start =
          get_in(node, [Access.key(:source_span), Access.key(:start_line)]) || start_line

        %{
          id: to_string(node.id),
          label: node_label(node),
          start_line: node_start,
          lines: if(node_source, do: String.split(node_source, "\n"), else: [node_label(node)]),
          source_html: node_html
        }
      end)

    %{
      blocks: [entry_block | target_blocks],
      edges: branch_edges
    }
  end

  defp format_control_label({:clause_match, n}), do: "match #{n}"
  defp format_control_label({:clause_fail, n}), do: "fail #{n}"
  defp format_control_label(other), do: inspect(other)

  defp branch_color({:clause_match, _}), do: "#16a34a"
  defp branch_color({:clause_fail, _}), do: "#dc2626"
  defp branch_color(_), do: "#ea580c"

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
        source = extract_source(f)
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

  defp extract_source(%{type: :function_def, source_span: %{file: file, start_line: start}})
       when is_binary(file) and is_integer(start) do
    case File.read(file) do
      {:ok, content} ->
        end_line = find_end_line(content, start)

        content
        |> String.split("\n")
        |> Enum.slice((start - 1)..(end_line - 1))
        |> Enum.join("\n")
        |> format_source()

      _ ->
        nil
    end
  end

  defp extract_source(_), do: nil

  defp extract_node_source(%{source_span: %{file: file, start_line: line}})
       when is_binary(file) and is_integer(line) do
    case File.read(file) do
      {:ok, content} ->
        content
        |> String.split("\n")
        |> Enum.at(line - 1, "")
        |> String.trim()

      _ ->
        nil
    end
  end

  defp extract_node_source(_), do: nil

  defp format_source(source) do
    Code.format_string!(source) |> IO.iodata_to_binary()
  rescue
    _ -> String.trim(source)
  end

  defp find_end_line(content, start) do
    content
    |> String.split("\n")
    |> Enum.drop(start)
    |> Enum.with_index(start + 1)
    |> Enum.find_value(start + 2, fn {line, idx} ->
      trimmed = String.trim(line)
      if trimmed == "end" or String.starts_with?(trimmed, "end "), do: idx
    end)
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

  defp node_label(%{type: :call, meta: meta}) do
    case meta[:module] do
      nil -> "#{meta[:function]}/#{meta[:arity]}"
      mod -> "#{inspect(mod)}.#{meta[:function]}/#{meta[:arity]}"
    end
  end

  defp node_label(%{type: :var, meta: %{name: name}}), do: to_string(name)
  defp node_label(%{type: :literal, meta: %{value: val}}), do: inspect(val)
  defp node_label(%{type: type}), do: to_string(type)

  defp node_label_short(%{type: :call, meta: meta}) do
    case meta[:module] do
      nil -> "#{meta[:function]}/#{meta[:arity]}"
      mod -> "#{inspect(mod)}.#{meta[:function]}/#{meta[:arity]}"
    end
  end

  defp node_label_short(%{meta: %{name: name}}), do: to_string(name)
  defp node_label_short(%{type: type}), do: to_string(type)

  defp detect_file(nodes) do
    Enum.find_value(nodes, fn n ->
      get_in(n, [Access.key(:source_span), Access.key(:file)])
    end)
  end
end
