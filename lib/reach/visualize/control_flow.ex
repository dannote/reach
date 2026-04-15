defmodule Reach.Visualize.ControlFlow do
  @moduledoc false

  alias Reach.{IR, Visualize}

  def build(all_nodes, graph) do
    modules =
      all_nodes
      |> Enum.filter(&(&1.type == :module_def))
      |> Enum.map(fn mod ->
        func_nodes =
          IR.all_nodes(mod)
          |> Enum.filter(&(&1.type == :function_def))
          |> sort_by_line()

        functions =
          func_nodes
          |> Enum.map(&build_function(&1, graph))

        %{
          module: inspect(mod.meta[:name]),
          file: span_field(mod, :file),
          functions: functions
        }
      end)

    top_funcs = find_top_level_functions(all_nodes, modules)

    if top_funcs != [] do
      top = %{
        module: nil,
        file: Enum.find_value(top_funcs, &span_field(&1, :file)),
        functions: Enum.map(top_funcs, &build_function(&1, graph))
      }

      [top | modules]
    else
      modules
    end
  end

  defp build_function(func, graph) do
    func_nodes = IR.all_nodes(func)
    func_node_ids = MapSet.new(func_nodes, & &1.id)

    # Get control dependence edges within this function
    control_edges =
      Reach.edges(graph)
      |> Enum.filter(fn e ->
        is_integer(e.v1) and is_integer(e.v2) and
          e.v1 in func_node_ids and e.v2 in func_node_ids and
          control_edge?(e.label)
      end)

    # Check for multi-clause function
    function_clauses =
      func.children
      |> Enum.filter(&(&1.type == :clause and &1.meta[:kind] == :function_clause))

    {blocks, edges} =
      if length(function_clauses) > 1 do
        build_multi_clause(func, function_clauses)
      else
        build_blocks(func, func_nodes, control_edges)
      end

    %{
      id: to_string(func.id),
      name: to_string(func.meta[:name]),
      arity: func.meta[:arity] || 0,
      blocks: %{blocks: blocks, edges: edges}
    }
  end

  # Multi-clause dispatch: each function_clause is a separate block
  defp build_multi_clause(func, clauses) do
    name = func.meta[:name]
    arity = func.meta[:arity] || 0

    dispatch =
      make_block(
        to_string(func.id),
        "#{name}/#{arity} dispatch",
        span_field(func, :start_line) || 1,
        nil,
        nil
      )

    clause_blocks =
      clauses
      |> Enum.with_index()
      |> Enum.map(fn {clause, idx} ->
        source = extract_clause_source(func, clause, clauses)
        start_line = span_field(clause, :start_line) || span_field(func, :start_line) || 1
        pattern = clause_pattern(clause)

        make_block(
          to_string(clause.id),
          "#{name}/#{arity} clause #{idx + 1}: #{pattern}",
          start_line,
          source,
          Visualize.highlight_source(source)
        )
      end)

    edges =
      clauses
      |> Enum.with_index()
      |> Enum.map(fn {clause, idx} ->
        %{
          id: "dispatch_#{func.id}_#{clause.id}",
          source: to_string(func.id),
          target: to_string(clause.id),
          label: clause_pattern(clause),
          color: dispatch_color(idx)
        }
      end)

    {[dispatch | clause_blocks], edges}
  end

  # Single function: build real basic blocks from CFG
  defp build_blocks(func, _func_nodes, _control_edges) do
    cfg = Reach.ControlFlow.build(func)
    all_func_nodes = IR.all_nodes(func)
    node_map = Map.new(all_func_nodes, &{&1.id, &1})
    cfg_edges = Graph.edges(cfg)

    sequential_map =
      cfg_edges
      |> Enum.filter(&(&1.label == :sequential))
      |> Map.new(&{&1.v1, &1.v2})

    # Block leaders: targets of branch edges + entry successors
    branch_targets =
      cfg_edges
      |> Enum.filter(fn e ->
        match?({:clause_match, _}, e.label) or match?({:clause_fail, _}, e.label)
      end)
      |> Enum.map(& &1.v2)
      |> MapSet.new()

    entry_successors =
      cfg_edges
      |> Enum.filter(&(&1.v1 == :entry))
      |> Enum.map(& &1.v2)
      |> MapSet.new()

    leaders = MapSet.union(branch_targets, entry_successors)

    # Build blocks from sequential chains
    blocks =
      leaders
      |> Enum.filter(&is_integer/1)
      |> Enum.map(fn leader_id ->
        chain = follow_chain(leader_id, sequential_map, branch_targets)
        chain_nodes = Enum.map(chain, &Map.get(node_map, &1)) |> Enum.reject(&is_nil/1)
        source_text = extract_block_source_lines(chain_nodes)
        start_line = find_first_line(chain_nodes)

        make_block(
          to_string(leader_id),
          block_label(chain_nodes, func),
          start_line,
          source_text,
          Visualize.highlight_source(source_text)
        )
      end)
      |> Enum.reject(&(Enum.empty?(&1.lines) and is_nil(&1.source_html)))

    edges = build_block_edges(cfg_edges, blocks, sequential_map, leaders, node_map)

    case blocks do
      [] ->
        source = Visualize.extract_func_source(func)

        {[
           make_block(
             to_string(func.id),
             "#{func.meta[:name]}/#{func.meta[:arity]}",
             span_line(func),
             source,
             Visualize.highlight_source(source)
           )
         ], []}

      _ ->
        {blocks, edges}
    end
  end

  defp build_block_edges(cfg_edges, blocks, sequential_map, leaders, node_map) do
    block_id_set = MapSet.new(blocks, &String.to_integer(&1.id))

    cfg_edges
    |> Enum.filter(fn e ->
      is_integer(e.v1) and is_integer(e.v2) and
        (match?({:clause_match, _}, e.label) or match?({:clause_fail, _}, e.label))
    end)
    |> Enum.map(fn e ->
      src = find_block_leader(e.v1, sequential_map, leaders)
      target_node = Map.get(node_map, e.v2)

      %{
        id: "cfg_#{e.v1}_#{e.v2}",
        source: to_string(src),
        target: to_string(e.v2),
        label: readable_edge_label(e.label, target_node),
        color: cfg_edge_color(e.label)
      }
    end)
    |> Enum.reject(&(&1.source == &1.target))
    |> Enum.filter(fn e ->
      s = safe_to_int(e.source)
      t = safe_to_int(e.target)
      (s == nil or s in block_id_set) and (t == nil or t in block_id_set)
    end)
    |> Enum.uniq_by(&{&1.source, &1.target})
  end

  defp follow_chain(start, sequential_map, branch_targets) do
    do_follow(start, sequential_map, branch_targets, [start])
  end

  defp do_follow(current, sequential_map, branch_targets, acc) do
    case Map.get(sequential_map, current) do
      nil ->
        Enum.reverse(acc)

      next when is_integer(next) ->
        if next in branch_targets,
          do: Enum.reverse(acc),
          else: do_follow(next, sequential_map, branch_targets, [next | acc])

      _ ->
        Enum.reverse(acc)
    end
  end

  defp find_block_leader(node_id, sequential_map, leaders) do
    if node_id in leaders do
      node_id
    else
      reverse = Map.new(sequential_map, fn {k, v} -> {v, k} end)
      walk_back(node_id, reverse, leaders, 20)
    end
  end

  defp walk_back(id, _reverse, _leaders, 0), do: id

  defp walk_back(id, reverse, leaders, depth) do
    if id in leaders do
      id
    else
      case Map.get(reverse, id) do
        nil -> id
        prev -> walk_back(prev, reverse, leaders, depth - 1)
      end
    end
  end

  defp find_first_line(nodes) do
    # Check nodes directly, then their children
    direct = Enum.find_value(nodes, &span_line/1)

    if direct do
      direct
    else
      nodes
      |> Enum.flat_map(fn n -> n.children end)
      |> Enum.find_value(1, &span_line/1)
    end
  end

  defp span_line(node), do: span_field(node, :start_line)

  defp safe_to_int(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp safe_to_int(_), do: nil

  defp block_label(nodes, func) do
    first = List.first(nodes)

    cond do
      is_nil(first) -> "block"
      first.type == :clause -> "#{func.meta[:name]}/#{func.meta[:arity]} #{ir_label(first)}"
      first.type == :call -> ir_label(first)
      first.type == :var -> ir_label(first)
      first.type in [:case, :if, :cond] -> to_string(first.type)
      true -> ir_label(first)
    end
  end

  defp readable_edge_label(_label, %{type: :clause, meta: %{kind: :true_branch}}), do: "true"
  defp readable_edge_label(_label, %{type: :clause, meta: %{kind: :false_branch}}), do: "false"

  defp readable_edge_label(_label, %{
         type: :clause,
         meta: %{kind: :case_clause},
         children: [first | _]
       }),
       do: ir_label(first)

  defp readable_edge_label({:clause_fail, _}, _), do: "no match"
  defp readable_edge_label({:clause_match, _}, _), do: "match"
  defp readable_edge_label(label, _), do: cfg_edge_label(label)

  defp cfg_edge_label({:clause_match, n}), do: "match #{n}"
  defp cfg_edge_label({:clause_fail, n}), do: "fail #{n}"
  defp cfg_edge_label(:return), do: "return"
  defp cfg_edge_label(other), do: inspect(other)

  defp cfg_edge_color({:clause_match, _}), do: "#16a34a"
  defp cfg_edge_color({:clause_fail, _}), do: "#dc2626"
  defp cfg_edge_color(:return), do: "#6b7280"
  defp cfg_edge_color(_), do: "#ea580c"

  defp extract_block_source_lines(nodes) do
    nodes_with_lines =
      nodes
      |> Enum.filter(&span_line/1)
      |> Enum.sort_by(&span_line/1)

    case nodes_with_lines do
      [] ->
        # No source spans — try to get source from children
        child_lines =
          nodes
          |> Enum.flat_map(fn n -> n.children end)
          |> Enum.filter(&span_line/1)
          |> Enum.sort_by(&span_line/1)

        case child_lines do
          [] -> nil
          sorted -> read_line_range(sorted)
        end

      sorted ->
        read_line_range(sorted)
    end
  end

  defp read_line_range(sorted_nodes) do
    file = span_field(hd(sorted_nodes), :file)
    first_line = span_line(hd(sorted_nodes))
    last_line = span_line(List.last(sorted_nodes))

    if is_nil(file) do
      sorted_nodes |> Enum.map(&ir_label/1) |> Enum.uniq() |> Enum.join("\n")
    else
      case File.read(file) do
        {:ok, content} ->
          content
          |> String.split("\n")
          |> Enum.slice((first_line - 1)..max(first_line - 1, last_line - 1))
          |> Enum.map_join("\n", &String.trim_leading/1)

        _ ->
          nil
      end
    end
  end

  # ── Block construction ──

  defp make_block(id, label, start_line, source, source_html) do
    %{
      id: id,
      label: label,
      start_line: start_line,
      lines: if(source, do: String.split(source, "\n"), else: []),
      source_html: source_html
    }
  end

  # ── IR-based labeling ──

  defp ir_label(%{type: :call, meta: meta}) do
    case meta[:module] do
      nil -> "#{meta[:function]}/#{meta[:arity]}"
      mod -> "#{inspect(mod)}.#{meta[:function]}/#{meta[:arity]}"
    end
  end

  defp ir_label(%{type: :var, meta: %{name: name}}), do: to_string(name)
  defp ir_label(%{type: :literal, meta: %{value: val}}), do: inspect(val)

  defp ir_label(%{type: :tuple, children: children}) do
    "{" <> Enum.map_join(children, ", ", &ir_label/1) <> "}"
  end

  defp ir_label(%{type: :clause, meta: %{kind: kind}}), do: "#{kind}"
  defp ir_label(%{type: type}), do: to_string(type)

  # ── Edge labeling ──

  defp control_edge?({:control, _}), do: true
  defp control_edge?(_), do: false

  defp dispatch_color(0), do: "#16a34a"
  defp dispatch_color(1), do: "#2563eb"
  defp dispatch_color(2), do: "#ea580c"
  defp dispatch_color(_), do: "#7c3aed"

  # ── Clause extraction ──

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

  defp extract_clause_source(func, clause, all_clauses) do
    file = span_field(func, :file)
    clause_start = span_field(clause, :start_line)

    with true <- is_binary(file) and is_integer(clause_start),
         end_line <- clause_end_line(func, clause_start, all_clauses),
         {:ok, content} <- File.read(file) do
      content
      |> String.split("\n")
      |> Enum.slice((clause_start - 1)..(end_line - 1))
      |> Enum.join("\n")
      |> Visualize.format_source()
    else
      _ -> nil
    end
  end

  defp clause_end_line(func, clause_start, all_clauses) do
    next_start =
      all_clauses
      |> Enum.map(&(span_field(&1, :start_line) || 0))
      |> Enum.filter(&(&1 > clause_start))
      |> Enum.min(fn -> nil end)

    func_end =
      case span_field(func, :file) do
        nil -> nil
        file -> find_func_end(file, span_field(func, :start_line) || 1)
      end

    (next_start && next_start - 1) || func_end || clause_start + 10
  end

  defp find_func_end(file, start_line) do
    cache = Process.get(:reach_def_end_cache, %{})

    case Map.get(cache, file) do
      nil -> nil
      line_map -> Map.get(line_map, start_line)
    end
  end

  # ── Helpers ──

  defp sort_by_line(nodes) do
    Enum.sort_by(nodes, &(span_field(&1, :start_line) || 0))
  end

  defp find_top_level_functions(all_nodes, modules) do
    module_func_ids =
      modules
      |> Enum.flat_map(fn m -> Enum.map(m.functions, & &1.id) end)
      |> MapSet.new()

    all_nodes
    |> Enum.filter(&(&1.type == :function_def))
    |> Enum.reject(&(to_string(&1.id) in module_func_ids))
    |> sort_by_line()
  end

  defp span_field(%{source_span: %{} = span}, field), do: Map.get(span, field)
  defp span_field(_, _), do: nil
end
