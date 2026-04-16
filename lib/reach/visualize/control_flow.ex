defmodule Reach.Visualize.ControlFlow do
  @moduledoc false

  alias Reach.{IR, Visualize}

  def build(all_nodes, _graph) do
    modules =
      all_nodes
      |> Enum.filter(&(&1.type == :module_def))
      |> Enum.map(fn mod ->
        file = span_field(mod, :file)

        func_nodes =
          IR.all_nodes(mod)
          |> Enum.filter(&(&1.type == :function_def))
          |> Enum.sort_by(&(span_field(&1, :start_line) || 0))

        preamble = extract_preamble(mod, file)
        functions = Enum.map(func_nodes, &build_function(&1, file))

        %{
          module: inspect(mod.meta[:name]),
          file: file,
          preamble: preamble,
          functions: functions
        }
      end)

    top_funcs = find_top_level_functions(all_nodes, modules)

    if top_funcs != [] do
      file = Enum.find_value(top_funcs, &span_field(&1, :file))

      top = %{
        module: nil,
        file: file,
        preamble: nil,
        functions: Enum.map(top_funcs, &build_function(&1, file))
      }

      [top | modules]
    else
      modules
    end
  end

  # ── Module preamble (use/import/alias/@attrs) ──

  defp extract_preamble(mod, file) when is_binary(file) do
    func_starts =
      IR.all_nodes(mod)
      |> Enum.filter(&(&1.type == :function_def))
      |> Enum.map(&(span_field(&1, :start_line) || 999_999))

    first_func_line = Enum.min(func_starts, fn -> 999_999 end)
    mod_start = span_field(mod, :start_line) || 1

    case File.read(file) do
      {:ok, content} ->
        lines = String.split(content, "\n")

        preamble_end = max(mod_start, first_func_line - 2)

        preamble_lines =
          lines
          |> Enum.slice(mod_start..preamble_end)
          |> Enum.filter(&preamble_line?/1)

        if preamble_lines == [] do
          nil
        else
          Visualize.highlight_source(Enum.join(preamble_lines, "\n"))
        end

      _ ->
        nil
    end
  end

  defp extract_preamble(_, _), do: nil

  defp preamble_line?(line) do
    trimmed = String.trim(line)

    String.starts_with?(trimmed, "@") or
      String.starts_with?(trimmed, "use ") or
      String.starts_with?(trimmed, "import ") or
      String.starts_with?(trimmed, "alias ") or
      String.starts_with?(trimmed, "require ")
  end

  # ── Function builder ──

  defp build_function(func, file) do
    start_line = span_field(func, :start_line) || 1
    Visualize.ensure_def_cache(file)

    function_clauses =
      func.children
      |> Enum.filter(&(&1.type == :clause and &1.meta[:kind] == :function_clause))

    {nodes, edges} =
      if length(function_clauses) > 1 do
        build_multi_clause(func, function_clauses, file)
      else
        build_expression_nodes(func, file, start_line)
      end

    %{
      id: to_string(func.id),
      name: to_string(func.meta[:name]),
      arity: func.meta[:arity] || 0,
      nodes: nodes,
      edges: edges
    }
  end

  # ── Multi-clause dispatch ──

  defp build_multi_clause(func, clauses, file) do
    name = func.meta[:name]
    arity = func.meta[:arity] || 0
    func_id = to_string(func.id)

    dispatch = %{
      id: func_id,
      type: :entry,
      label: "#{name}/#{arity} dispatch",
      start_line: span_field(func, :start_line) || 1,
      end_line: span_field(func, :start_line) || 1,
      source_html: nil,
      parent_id: nil
    }

    clause_nodes =
      clauses
      |> Enum.with_index()
      |> Enum.map(fn {clause, idx} ->
        source = extract_clause_source(func, clause, clauses, file)
        cl_start = span_field(clause, :start_line) || span_field(func, :start_line) || 1

        %{
          id: to_string(clause.id),
          type: :clause,
          label: "clause #{idx + 1}: #{clause_pattern(clause)}",
          start_line: cl_start,
          end_line: clause_end_line(func, cl_start, clauses, file),
          source_html: Visualize.highlight_source(source),
          parent_id: func_id
        }
      end)

    edges =
      clauses
      |> Enum.with_index()
      |> Enum.map(fn {clause, idx} ->
        %{
          id: "dispatch_#{func.id}_#{clause.id}",
          source: func_id,
          target: to_string(clause.id),
          label: clause_pattern(clause),
          edge_type: :branch,
          color: dispatch_color(idx)
        }
      end)

    {[dispatch | clause_nodes], edges}
  end

  # ── Expression-level nodes from AST ──

  defp build_expression_nodes(func, file, func_start) do
    source = Visualize.extract_func_source(func)
    func_end = func_end_line(func, file)

    if func_end <= func_start do
      fallback_single_block(func, source, func_start)
    else
      build_multi_line_function(func, file, source, func_start, func_end)
    end
  end

  defp build_multi_line_function(func, file, source, func_start, func_end) do
    case parse_function_ast(source) do
      {:ok, body_exprs} ->
        offset = func_start - 1
        func_id = to_string(func.id)

        entry =
          make_node(
            func_id,
            :entry,
            "#{func.meta[:name]}/#{func.meta[:arity]}",
            func_start,
            func_start,
            highlight_line(file, func_start)
          )

        exit_node =
          make_node(
            "#{func.id}_exit",
            :exit,
            "end",
            func_end,
            func_end,
            highlight_line(file, func_end)
          )

        {body_nodes, body_edges, body_leaves} =
          walk_body(body_exprs, func_id, file, offset, max(func_start, func_end - 1))

        entry_edge = seq_edge(entry.id, first_id(body_nodes))

        exit_edges =
          if length(body_leaves) > 1 do
            Enum.map(body_leaves, &converge_edge(&1, exit_node.id))
          else
            Enum.map(body_leaves, &seq_edge(&1, exit_node.id))
          end
          |> Enum.reject(&is_nil/1)

        all_nodes = [entry | body_nodes] ++ [exit_node]
        all_edges = Enum.reject([entry_edge | body_edges] ++ exit_edges, &is_nil/1)

        {all_nodes, all_edges}

      _ ->
        fallback_single_block(func, source, func_start)
    end
  end

  defp connect_leaves(_prev_leaves, _target, 0), do: []

  defp connect_leaves(prev_leaves, target, _idx) do
    edge_fn = if length(prev_leaves) > 1, do: &converge_edge/2, else: &seq_edge/2
    prev_leaves |> Enum.map(&edge_fn.(&1, target)) |> Enum.reject(&is_nil/1)
  end

  defp resolve_start(line, _prev_end, _fallback, offset) when is_integer(line), do: line + offset

  defp resolve_start(nil, prev_end, _fallback, _offset) when is_integer(prev_end),
    do: prev_end + 1

  defp resolve_start(nil, nil, fallback, _offset) when is_integer(fallback), do: fallback
  defp resolve_start(nil, nil, _fallback, offset), do: 1 + offset

  defp expr_end_line(meta, offset, next_start, line) do
    case get_in(meta, [:end, :line]) do
      nil -> if next_start, do: next_start - 1, else: line
      end_l -> end_l + offset
    end
  end

  # Walks a list of expressions, returns {nodes, edges, leaf_ids}.
  # leaf_ids are the IDs of nodes from which flow exits this body
  # (the last expression's leaves, or last sequential node).

  defp compute_starts(exprs, offset, fallback_line) do
    {starts, _} =
      Enum.map_reduce(exprs, nil, fn expr, prev_end ->
        meta = extract_meta(expr)
        start = resolve_start(meta[:line], prev_end, fallback_line, offset)
        end_l = get_in(meta, [:end, :line]) || meta[:line]
        actual_end = if end_l, do: end_l + offset, else: start
        {start, actual_end}
      end)

    starts
  end

  defp walk_body([], _parent_id, _file, _offset, _body_end), do: {[], [], []}

  defp walk_body(exprs, parent_id, file, offset, body_end) do
    starts = compute_starts(exprs, offset, body_end)
    indexed = Enum.with_index(exprs)

    {all_nodes, all_edges, last_leaves} =
      Enum.reduce(indexed, {[], [], []}, fn {expr, idx}, {nodes_acc, edges_acc, prev_leaves} ->
        meta = extract_meta(expr)
        line = Enum.at(starts, idx)
        next_start = Enum.at(starts, idx + 1)
        last_boundary = if(is_nil(next_start) and body_end, do: body_end + 1, else: next_start)
        end_line = expr_end_line(meta, offset, last_boundary, line)

        expr_id = "#{parent_id}_e#{idx}"

        {expr_nodes, expr_edges, expr_leaves} =
          build_expr_node(expr, expr_id, parent_id, file, line, end_line, offset)

        first_target = first_id(expr_nodes)

        connect_edges = connect_leaves(prev_leaves, first_target, idx)

        {nodes_acc ++ expr_nodes, edges_acc ++ connect_edges ++ expr_edges, expr_leaves}
      end)

    merge_sequential(all_nodes, all_edges, last_leaves, file)
  end

  defp merge_sequential(nodes, edges, leaves, file) do
    edge_targets = Enum.frequencies_by(edges, & &1.target)
    edge_sources = Enum.frequencies_by(edges, & &1.source)
    seq_ids = MapSet.new(nodes |> Enum.filter(&(&1.type == :sequential)) |> Enum.map(& &1.id))

    seq_edges =
      MapSet.new(
        edges
        |> Enum.filter(&(&1.edge_type == :sequential))
        |> Enum.map(&{&1.source, &1.target})
      )

    mergeable? = fn id ->
      id in seq_ids and Map.get(edge_targets, id, 0) == 1 and Map.get(edge_sources, id, 0) <= 1
    end

    {merged_nodes, id_map} =
      Enum.reduce(nodes, {[], %{}}, fn node, {acc, remap} ->
        try_merge_node(node, acc, remap, mergeable?, file, seq_edges)
      end)

    merged_nodes = Enum.reverse(merged_nodes)
    kept_ids = MapSet.new(merged_nodes, & &1.id)

    merged_edges =
      edges
      |> Enum.map(fn e ->
        %{e | source: remap_id(id_map, e.source), target: remap_id(id_map, e.target)}
      end)
      |> Enum.reject(&(&1.source == &1.target))
      |> Enum.filter(&(&1.source in kept_ids and &1.target in kept_ids))

    merged_leaves = leaves |> Enum.map(&remap_id(id_map, &1)) |> Enum.uniq()

    {merged_nodes, merged_edges, merged_leaves}
  end

  defp try_merge_node(
         node,
         [%{type: :sequential} = prev | rest],
         remap,
         mergeable?,
         file,
         seq_edges
       ) do
    if node.type == :sequential and mergeable?.(node.id) and {prev.id, node.id} in seq_edges do
      combined = %{
        prev
        | end_line: node.end_line,
          source_html: highlight_lines(file, prev.start_line, node.end_line)
      }

      {[combined | rest], Map.put(remap, node.id, prev.id)}
    else
      {[node, prev | rest], remap}
    end
  end

  defp try_merge_node(node, acc, remap, _mergeable?, _file, _seq_edges), do: {[node | acc], remap}

  defp remap_id(map, id), do: Map.get(map, id, id)

  defp build_expr_node(expr, id, parent_id, file, line, end_line, offset) do
    case classify_expr(expr) do
      :branch_if ->
        inner = unwrap_branch(expr)
        {nodes, edges, leaves} = build_if_node(inner, id, parent_id, file, line, end_line, offset)
        add_pipe_tail(expr, inner, id, {nodes, edges, leaves}, file, end_line, offset)

      :branch_case ->
        inner = unwrap_branch(expr)

        {nodes, edges, leaves} =
          build_case_node(inner, id, parent_id, file, line, end_line, offset)

        add_pipe_tail(expr, inner, id, {nodes, edges, leaves}, file, end_line, offset)

      _ ->
        node =
          make_node(id, :sequential, nil, line, end_line, highlight_lines(file, line, end_line))

        {[node], [], [id]}
    end
  end

  defp add_pipe_tail(outer, inner, id, {nodes, edges, leaves}, file, end_line, offset) do
    if outer == inner do
      {nodes, edges, leaves}
    else
      inner_end = get_in(extract_meta(inner), [:end, :line])

      if inner_end do
        tail_id = "#{id}_pipe"
        pipe_start = inner_end + offset + 1
        pipe_end = max(pipe_start, end_line)

        tail =
          make_node(
            tail_id,
            :sequential,
            nil,
            pipe_start,
            pipe_end,
            highlight_lines(file, pipe_start, pipe_end)
          )

        conv = leaves |> Enum.map(&converge_edge(&1, tail_id)) |> Enum.reject(&is_nil/1)
        {nodes ++ [tail], edges ++ conv, [tail_id]}
      else
        {nodes, edges, leaves}
      end
    end
  end

  # ── If/unless node ──

  defp build_if_node(expr, id, _parent_id, file, _line, _end_line, offset) do
    {form, meta, [_cond | rest]} = expr
    if_line = (meta[:line] || 1) + offset
    if_end = (get_in(meta, [:end, :line]) || meta[:line] || 1) + offset

    blocks =
      case rest do
        [kw] when is_list(kw) -> kw
        _ -> [do: nil]
      end

    label = to_string(form)
    branch_node = make_node(id, :branch, label, if_line, if_end, highlight_line(file, if_line))

    do_body = blocks[:do]
    else_body = blocks[:else]

    {do_nodes, do_edges, do_leaves} = build_arm(do_body, "#{id}_do", id, file, offset, if_end)
    do_edge = branch_edge(id, first_id(do_nodes), "true", "#16a34a")

    {else_nodes, else_edges, else_leaves, else_edge} =
      if else_body do
        {en, ee, el} = build_arm(else_body, "#{id}_else", id, file, offset, if_end)
        {en, ee, el, branch_edge(id, first_id(en), "false", "#dc2626")}
      else
        {[], [], [id], nil}
      end

    all_nodes = [branch_node] ++ do_nodes ++ else_nodes
    all_edges = Enum.reject([do_edge, else_edge], &is_nil/1) ++ do_edges ++ else_edges
    all_leaves = do_leaves ++ else_leaves

    {all_nodes, all_edges, all_leaves}
  end

  # ── Case node ──

  defp build_case_node(expr, id, _parent_id, file, _line, _end_line, offset) do
    {:case, meta, [_matched, [do: clauses]]} = expr
    case_line = (meta[:line] || 1) + offset
    case_end = (get_in(meta, [:end, :line]) || meta[:line] || 1) + offset

    branch_node =
      make_node(id, :branch, "case", case_line, case_end, highlight_line(file, case_line))

    {clause_nodes, clause_edges, clause_leaves} =
      clauses
      |> Enum.with_index()
      |> Enum.reduce({[], [], []}, fn {{:->, clause_meta, [patterns, body]}, idx},
                                      {n_acc, e_acc, l_acc} ->
        clause_line = (clause_meta[:line] || 1) + offset
        pattern_str = Macro.to_string(hd(patterns)) |> String.slice(0, 40)
        clause_id = "#{id}_c#{idx}"

        clause_node =
          make_node(
            clause_id,
            :clause,
            pattern_str,
            clause_line,
            clause_line,
            highlight_line(file, clause_line)
          )

        {arm_nodes, arm_edges, arm_leaves} =
          build_arm(body, clause_id, id, file, offset, case_end)

        edge = branch_edge(id, clause_id, pattern_str, clause_color(idx))
        arm_edge = seq_edge(clause_id, first_id(arm_nodes))

        leaves = if arm_leaves == [], do: [clause_id], else: arm_leaves

        {n_acc ++ [clause_node | arm_nodes],
         e_acc ++ Enum.reject([edge, arm_edge | arm_edges], &is_nil/1), l_acc ++ leaves}
      end)

    {[branch_node | clause_nodes], clause_edges, clause_leaves}
  end

  # ── Branch arm (shared by if/case) ──

  defp build_arm(body, arm_id, _parent_id, file, offset, arm_line) do
    exprs =
      case body do
        {:__block__, _, es} -> es
        nil -> []
        single -> [single]
      end

    walk_body(exprs, arm_id, file, offset, arm_line)
  end

  # ── Leaf collection ──

  # ── Fallback ──

  defp fallback_single_block(func, source, start_line) do
    node =
      make_node(
        to_string(func.id),
        :entry,
        "#{func.meta[:name]}/#{func.meta[:arity]}",
        start_line,
        start_line,
        Visualize.highlight_source(source)
      )

    {[node], []}
  end

  # ── Node/edge constructors ──

  defp make_node(id, type, label, start_line, end_line, source_html) do
    %{
      id: id,
      type: type,
      label: label,
      start_line: start_line,
      end_line: end_line,
      source_html: source_html,
      parent_id: nil
    }
  end

  defp seq_edge(source, target) when is_binary(source) and is_binary(target) do
    %{
      id: "seq_#{source}_#{target}",
      source: source,
      target: target,
      label: "",
      edge_type: :sequential,
      color: "#94a3b8"
    }
  end

  defp seq_edge(_, _), do: nil

  defp converge_edge(source, target) when is_binary(source) and is_binary(target) do
    %{
      id: "conv_#{source}_#{target}",
      source: source,
      target: target,
      label: "",
      edge_type: :converge,
      color: "#3b82f6"
    }
  end

  defp converge_edge(_, _), do: nil

  defp branch_edge(source, target, label, color) when is_binary(target) do
    %{
      id: "br_#{source}_#{target}",
      source: source,
      target: target,
      label: label,
      edge_type: :branch,
      color: color
    }
  end

  defp branch_edge(_, _, _, _), do: nil

  defp first_id([%{id: id} | _]), do: id
  defp first_id(_), do: nil

  defp dispatch_color(0), do: "#16a34a"
  defp dispatch_color(1), do: "#2563eb"
  defp dispatch_color(2), do: "#ea580c"
  defp dispatch_color(_), do: "#7c3aed"

  defp clause_color(0), do: "#16a34a"
  defp clause_color(1), do: "#2563eb"
  defp clause_color(2), do: "#ea580c"
  defp clause_color(_), do: "#7c3aed"

  # ── AST helpers ──

  defp parse_function_ast(nil), do: :error

  defp parse_function_ast(source) do
    case Code.string_to_quoted(source, columns: true, token_metadata: true) do
      {:ok, {:def, _, [_, [do: body]]}} -> {:ok, normalize_body(body)}
      {:ok, {:defp, _, [_, [do: body]]}} -> {:ok, normalize_body(body)}
      {:ok, {:def, _, [_, [{:do, body} | _]]}} -> {:ok, normalize_body(body)}
      {:ok, {:defp, _, [_, [{:do, body} | _]]}} -> {:ok, normalize_body(body)}
      _ -> :error
    end
  end

  defp normalize_body({:__block__, _, exprs}), do: exprs
  defp normalize_body(nil), do: []
  defp normalize_body(single), do: [single]

  defp unwrap_branch({:|>, _, [left, _]}), do: unwrap_branch(left)
  defp unwrap_branch({:=, _, [_, right]}), do: unwrap_branch(right)
  defp unwrap_branch(expr), do: expr

  defp classify_expr({:if, _, _}), do: :branch_if
  defp classify_expr({:unless, _, _}), do: :branch_if
  defp classify_expr({:case, _, _}), do: :branch_case
  defp classify_expr({:cond, _, _}), do: :branch_cond
  defp classify_expr({:|>, _, [left, _]}), do: classify_expr(left)
  defp classify_expr({:=, _, [_, right]}), do: classify_expr(right)
  defp classify_expr(_), do: :sequential

  defp extract_meta({_, meta, _}) when is_list(meta), do: meta
  defp extract_meta(_), do: []

  # ── Source helpers ──

  defp highlight_line(file, line) when is_binary(file) and is_integer(line) do
    case read_line(file, line) do
      nil -> nil
      text -> Visualize.highlight_source(String.trim_leading(text))
    end
  end

  defp highlight_line(_, _), do: nil

  defp highlight_lines(file, from, to) when is_binary(file) do
    case File.read(file) do
      {:ok, content} ->
        content
        |> String.split("\n")
        |> Enum.slice((from - 1)..max(from - 1, to - 1))
        |> dedent()
        |> Enum.join("\n")
        |> Visualize.highlight_source()

      _ ->
        nil
    end
  end

  defp highlight_lines(_, _, _), do: nil

  defp dedent(lines) do
    min_indent =
      lines
      |> Enum.reject(&(String.trim(&1) == ""))
      |> Enum.map(fn line -> byte_size(line) - byte_size(String.trim_leading(line)) end)
      |> Enum.min(fn -> 0 end)

    Enum.map(lines, fn line -> String.slice(line, min_indent, byte_size(line)) end)
  end

  defp read_line(file, line) do
    case File.read(file) do
      {:ok, content} -> content |> String.split("\n") |> Enum.at(line - 1)
      _ -> nil
    end
  end

  # ── IR helpers ──

  defp clause_pattern(clause) do
    clause.children
    |> Enum.take_while(fn c ->
      c.meta[:binding_role] == :definition or
        c.type in [:literal, :tuple, :map, :list, :struct, :var]
    end)
    |> Enum.map_join(", ", &ir_label/1)
    |> case do
      "" -> "_"
      s -> s
    end
  end

  defp ir_label(%{type: :literal, meta: %{value: val}}), do: inspect(val)
  defp ir_label(%{type: :var, meta: %{name: name}}), do: to_string(name)
  defp ir_label(%{type: :tuple}), do: "{...}"
  defp ir_label(%{type: :map}), do: "%{...}"
  defp ir_label(%{type: type}), do: to_string(type)

  defp extract_clause_source(func, clause, all_clauses, file) do
    clause_start = span_field(clause, :start_line)

    with true <- is_binary(file) and is_integer(clause_start),
         end_line <- clause_end_line(func, clause_start, all_clauses, file) do
      case File.read(file) do
        {:ok, content} ->
          content
          |> String.split("\n")
          |> Enum.slice((clause_start - 1)..(end_line - 1))
          |> dedent()
          |> Enum.join("\n")
          |> Visualize.format_source()

        _ ->
          nil
      end
    else
      _ -> nil
    end
  end

  defp clause_end_line(func, clause_start, all_clauses, file) do
    next_start =
      all_clauses
      |> Enum.map(&(span_field(&1, :start_line) || 0))
      |> Enum.filter(&(&1 > clause_start))
      |> Enum.min(fn -> nil end)

    (next_start && next_start - 1) || func_end_line(func, file)
  end

  defp func_end_line(func, file) do
    if file, do: Visualize.ensure_def_cache(file)
    cache = Process.get(:reach_def_end_cache, %{})
    start = span_field(func, :start_line)

    case Map.get(cache, file) do
      nil -> (start || 1) + 10
      map -> Map.get(map, start, (start || 1) + 10)
    end
  end

  defp span_field(%{source_span: %{} = span}, field), do: Map.get(span, field)
  defp span_field(_, _), do: nil

  defp find_top_level_functions(all_nodes, modules) do
    module_func_ids =
      modules
      |> Enum.flat_map(fn m -> Enum.map(m.functions, & &1.id) end)
      |> MapSet.new()

    all_nodes
    |> Enum.filter(&(&1.type == :function_def))
    |> Enum.reject(&(to_string(&1.id) in module_func_ids))
    |> Enum.sort_by(&(span_field(&1, :start_line) || 0))
  end
end
