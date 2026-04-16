defmodule Reach.Visualize do
  @moduledoc false

  alias Reach.Visualize.ControlFlow

  # ── Public API ──

  def to_graph_json(graph, opts \\ []) do
    %{
      control_flow: ControlFlow.build(Reach.nodes(graph), graph),
      call_graph: call_graph_data(graph),
      data_flow: data_flow_data(graph, opts)
    }
  end

  def to_json(graph, opts \\ []) do
    unless Code.ensure_loaded?(Jason) do
      raise RuntimeError, "Jason is required. Add {:jason, ~s(~> 1.0)} to your deps."
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

  # ── Source extraction (used by ControlFlow module) ──

  @def_cache_key :reach_def_end_cache

  def ensure_def_cache(file) do
    cache = Process.get(@def_cache_key, %{})

    unless Map.has_key?(cache, file) do
      line_map = build_def_line_map(file)
      Process.put(@def_cache_key, Map.put(cache, file, line_map))
    end
  end

  def extract_func_source(%{type: :function_def, source_span: %{file: file, start_line: start}})
      when is_binary(file) and is_integer(start) do
    with end_line when is_integer(end_line) <- find_end_line(file, start),
         {:ok, content} <- File.read(file) do
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

  def highlight_source(nil), do: nil

  def highlight_source(source) do
    if Code.ensure_loaded?(Makeup) do
      source
      |> Makeup.highlight()
      |> String.replace(~r{^<pre class="highlight"><code>}, "")
      |> String.replace(~r{</code></pre>$}, "")
    else
      nil
    end
  end

  def format_source(source) do
    Code.format_string!(source) |> IO.iodata_to_binary()
  rescue
    _ -> String.trim(source)
  end

  # ── Call Graph ──

  defp call_graph_data(graph) do
    all_nodes = Reach.nodes(graph)
    call_graph = extract_call_graph(graph)
    module_name = detect_module(all_nodes)

    internal_funcs =
      all_nodes
      |> Enum.filter(&(&1.type == :function_def))
      |> Enum.map(fn f ->
        mod = f.meta[:module] || module_name
        {mod, f.meta[:name], f.meta[:arity] || 0}
      end)
      |> MapSet.new()

    raw_edges = Graph.edges(call_graph)

    # Filter: remove noise
    clean_edges =
      raw_edges
      |> Enum.reject(&garbage_call?/1)
      |> Enum.map(fn e ->
        # Resolve nil module to the detected module
        src = resolve_nil_module(e.v1, module_name)
        tgt = resolve_nil_module(e.v2, module_name)
        {src, tgt}
      end)
      |> Enum.reject(fn {src, tgt} -> src == tgt end)
      |> Enum.uniq()

    # Build module groups
    all_func_ids =
      clean_edges
      |> Enum.flat_map(fn {src, tgt} -> [src, tgt] end)
      |> Enum.uniq()

    modules =
      all_func_ids
      |> Enum.group_by(fn {mod, _, _} -> mod end)
      |> Enum.map(fn {mod, funcs} ->
        is_internal = Enum.any?(funcs, &(&1 in internal_funcs))

        %{
          id: format_module(mod),
          name: format_module(mod),
          file: if(is_internal, do: detect_file(all_nodes), else: nil),
          functions:
            funcs
            |> Enum.uniq()
            |> Enum.map(fn {_m, f, a} ->
              %{
                id: call_id(mod, f, a),
                name: "#{f}/#{a}",
                arity: a
              }
            end)
        }
      end)

    edges =
      clean_edges
      |> Enum.map(fn {{sm, sf, sa}, {tm, tf, ta}} ->
        %{
          id: "call_#{call_id(sm, sf, sa)}_#{call_id(tm, tf, ta)}",
          source: call_id(sm, sf, sa),
          target: call_id(tm, tf, ta),
          color: if(tm == module_name, do: "#7c3aed", else: "#94a3b8")
        }
      end)
      |> Enum.uniq_by(& &1.id)

    %{modules: modules, edges: edges}
  end

  defp garbage_call?(edge) do
    {_src_mod, _src_fn, _src_ar} = edge.v1
    {tgt_mod, tgt_fn, tgt_ar} = edge.v2

    cond do
      # Ecto query field access: :e.name/0, :s.timestamp/0
      is_atom(tgt_mod) and tgt_ar == 0 and field_access?(tgt_mod) ->
        true

      # Pipe operator
      tgt_fn == :\\ ->
        true

      # Kernel operators that aren't real calls
      tgt_fn in [:!, :&&, :||, :|>, :"~~~", :not, :and, :or, :in] ->
        true

      # AST leakage — module is a tuple/list
      not is_atom(tgt_mod) ->
        true

      # Ecto query DSL macros injected as local calls
      ecto_dsl_macro?(tgt_fn, tgt_ar) ->
        true

      true ->
        false
    end
  end

  @ecto_dsl_macros ~w(from assoc is_nil field type selected_as coalesce fragment subquery dynamic select_merge)a
  defp ecto_dsl_macro?(fn_name, arity), do: fn_name in @ecto_dsl_macros and arity <= 3

  defp field_access?(mod), do: ecto_binding?(mod) or variable_access?(mod)
  defp variable_access?(nil), do: false

  defp variable_access?(mod) when is_atom(mod) do
    name = Atom.to_string(mod)

    String.first(name) == String.downcase(String.first(name)) and
      not String.starts_with?(name, "Elixir.")
  end

  defp ecto_binding?(mod) when is_atom(mod) do
    s = Atom.to_string(mod)
    # Single-letter atoms like :e, :s, :t, :p — Ecto query bindings
    byte_size(s) <= 2 and s =~ ~r/^[a-z]{1,2}$/
  end

  defp resolve_nil_module({nil, func, arity}, module_name),
    do: {module_name || :_, func, arity}

  defp resolve_nil_module(mfa, _), do: mfa

  defp call_id(mod, func, arity) do
    "#{format_module(mod)}.#{func}/#{arity}"
  end

  defp format_module(nil), do: "_"
  defp format_module(mod) when is_atom(mod), do: inspect(mod)
  defp format_module(mod), do: inspect(mod)

  # ── Data Flow ──

  defp data_flow_data(graph, opts) do
    taint_results =
      case Keyword.get(opts, :taint) do
        nil -> []
        taint_opts -> Reach.taint_analysis(graph, taint_opts)
      end

    all_nodes = Reach.nodes(graph)
    func_nodes = Enum.filter(all_nodes, &(&1.type == :function_def))
    node_map = Map.new(all_nodes, &{&1.id, &1})
    node_to_func = build_node_to_func_map(func_nodes)

    data_edges =
      Reach.edges(graph)
      |> Enum.filter(&(is_integer(&1.v1) and is_integer(&1.v2) and data_edge?(&1.label)))

    involved_ids =
      data_edges
      |> Enum.flat_map(&[&1.v1, &1.v2])

    functions = build_data_flow_nodes(all_nodes, involved_ids, node_to_func, node_map)

    viz_ids = MapSet.new(functions, & &1.id)

    edges =
      data_edges
      |> Enum.map(fn e ->
        %{
          id: "df_#{e.v1}_#{e.v2}",
          source: to_string(e.v1),
          target: to_string(e.v2),
          label: to_string(extract_var_name(e.label) || "data"),
          color: "#16a34a"
        }
      end)
      |> Enum.filter(&(&1.source in viz_ids and &1.target in viz_ids))
      |> Enum.uniq_by(&{&1.source, &1.target})

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

  defp data_edge?({:data, _}), do: true

  defp data_edge?(:match_binding), do: true

  defp data_edge?(_), do: false

  defp extract_var_name({:data, var}), do: var
  defp extract_var_name(_), do: nil

  defp build_data_flow_nodes(all_nodes, involved_ids, node_to_func, node_map) do
    for n <- all_nodes,
        n.id in involved_ids,
        n.type not in [:module_def, :function_def, :clause],
        n.source_span[:start_line] != nil do
      func_id = Map.get(node_to_func, n.id)
      func = if func_id, do: Map.get(node_map, func_id)
      prefix = if func, do: "#{func.meta[:name]}/#{func.meta[:arity]} ", else: ""

      %{
        id: to_string(n.id),
        label: "#{prefix}L#{n.source_span[:start_line]}: #{ir_node_label(n)}",
        module: nil,
        start_line: n.source_span[:start_line],
        source_html: nil
      }
    end
  end

  defp ir_node_label(%{type: :var, meta: %{name: name}}), do: to_string(name)
  defp ir_node_label(%{type: :call, meta: meta}), do: to_string(meta[:function]) <> "(...)"
  defp ir_node_label(%{type: :match}), do: "="
  defp ir_node_label(%{type: :literal, meta: %{value: v}}), do: inspect(v)
  defp ir_node_label(%{type: type}), do: to_string(type)

  # ── Helpers ──

  defp build_node_to_func_map(func_nodes) do
    func_ids = MapSet.new(func_nodes, & &1.id)

    for func <- func_nodes,
        child <- Reach.IR.all_nodes(func),
        child.id not in func_ids,
        into: %{} do
      {child.id, func.id}
    end
  end

  defp find_end_line(file, start_line) do
    cache = Process.get(@def_cache_key, %{})

    case Map.get(cache, file) do
      nil ->
        line_map = build_def_line_map(file)
        Process.put(@def_cache_key, Map.put(cache, file, line_map))
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
          end_line = if end_meta, do: end_meta[:line], else: meta[:line]
          {node, Map.put(acc, meta[:line], end_line)}

        node, acc ->
          {node, acc}
      end)

    ranges
  end

  defp extract_call_graph(%Reach.Project{call_graph: cg}), do: cg
  defp extract_call_graph(%Reach.SystemDependence{call_graph: cg}), do: cg

  defp detect_module(all_nodes) do
    Enum.find_value(all_nodes, fn
      %{type: :module_def, meta: %{name: name}} -> name
      _ -> nil
    end)
  end

  defp detect_file(nodes) do
    Enum.find_value(nodes, fn n ->
      get_in(n, [Access.key(:source_span), Access.key(:file)])
    end)
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
