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

  # Single function: build blocks from control dependence edges
  defp build_blocks(func, func_nodes, control_edges) do
    source = Visualize.extract_func_source(func)
    start_line = span_field(func, :start_line) || 1

    # Entry block: the function itself
    entry =
      make_block(
        to_string(func.id),
        "#{func.meta[:name]}/#{func.meta[:arity]}",
        start_line,
        source,
        Visualize.highlight_source(source)
      )

    if control_edges == [] do
      {[entry], []}
    else
      # Find branch source nodes (nodes that have outgoing control edges)
      _branch_sources = MapSet.new(control_edges, & &1.v1)

      # Find branch target nodes
      branch_targets =
        control_edges
        |> Enum.map(& &1.v2)
        |> Enum.uniq()

      node_map = Map.new(func_nodes, &{&1.id, &1})

      # Build a block for each branch target
      target_blocks =
        branch_targets
        |> Enum.map(fn target_id ->
          node = Map.get(node_map, target_id)
          node_source = node && extract_node_line(node)
          node_start = (node && span_field(node, :start_line)) || start_line

          make_block(
            to_string(target_id),
            (node && ir_label(node)) || "block",
            node_start,
            node_source,
            Visualize.highlight_source(node_source)
          )
        end)

      # Build edges: remap source to entry block if source is inside function
      block_ids = MapSet.new([to_string(func.id) | Enum.map(target_blocks, & &1.id)])

      edges = build_control_edges(control_edges, block_ids, func.id)

      {[entry | target_blocks], edges}
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

  defp build_control_edges(control_edges, block_ids, func_id) do
    control_edges
    |> Enum.map(fn e ->
      src = if to_string(e.v1) in block_ids, do: to_string(e.v1), else: to_string(func_id)

      %{
        id: "cf_#{e.v1}_#{e.v2}",
        source: src,
        target: to_string(e.v2),
        label: control_label(e.label),
        color: control_color(e.label)
      }
    end)
    |> Enum.reject(&(&1.source == &1.target))
    |> Enum.uniq_by(&{&1.source, &1.target})
  end

  # ── Edge labeling ──

  defp control_edge?({:control, _}), do: true
  defp control_edge?(_), do: false

  defp control_label({:control, {:clause_match, n}}), do: "match #{n}"
  defp control_label({:control, {:clause_fail, n}}), do: "fail #{n}"
  defp control_label({:control, :sequential}), do: ""
  defp control_label({:control, other}), do: inspect(other)
  defp control_label(_), do: ""

  defp control_color({:control, {:clause_match, _}}), do: "#16a34a"
  defp control_color({:control, {:clause_fail, _}}), do: "#dc2626"
  defp control_color(_), do: "#ea580c"

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

  defp extract_node_line(%{source_span: %{file: file, start_line: line}})
       when is_binary(file) and is_integer(line) do
    case File.read(file) do
      {:ok, content} ->
        content |> String.split("\n") |> Enum.at(line - 1, "") |> String.trim()

      _ ->
        nil
    end
  end

  defp extract_node_line(_), do: nil

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
