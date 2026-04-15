defmodule Reach.Visualize.ControlFlow do
  @moduledoc false

  alias Reach.IR

  def build(all_nodes, graph) do
    modules =
      all_nodes
      |> Enum.filter(&(&1.type == :module_def))
      |> Enum.map(fn mod ->
        func_nodes =
          IR.all_nodes(mod)
          |> Enum.filter(&(&1.type == :function_def))

        functions =
          func_nodes
          |> group_multi_clause_functions()
          |> Enum.map(&build_function(&1, graph))

        %{
          module: inspect(mod.meta[:name]),
          file: get_span_field(mod, :file),
          functions: functions
        }
      end)

    top_funcs =
      all_nodes
      |> Enum.filter(&(&1.type == :function_def))
      |> Enum.reject(fn func ->
        Enum.any?(modules, fn m ->
          Enum.any?(
            m.functions,
            &(&1.name == to_string(func.meta[:name]) and &1.arity == func.meta[:arity])
          )
        end)
      end)

    if top_funcs != [] do
      top = %{
        module: nil,
        file: Enum.find_value(top_funcs, &get_span_field(&1, :file)),
        functions:
          top_funcs
          |> group_multi_clause_functions()
          |> Enum.map(&build_function(&1, graph))
      }

      [top | modules]
    else
      modules
    end
  end

  # Group function_def nodes by {name, arity} for multi-clause display
  defp group_multi_clause_functions(func_nodes) do
    func_nodes
    |> Enum.group_by(fn f -> {f.meta[:name], f.meta[:arity]} end)
    |> Enum.map(fn {{name, arity}, nodes} ->
      %{name: name, arity: arity || 0, nodes: nodes}
    end)
    |> Enum.sort_by(fn %{nodes: [first | _]} ->
      get_span_field(first, :start_line) || 0
    end)
  end

  defp build_function(%{name: name, arity: arity, nodes: func_nodes}, graph) do
    {blocks, edges} =
      if length(func_nodes) > 1 do
        build_multi_clause_blocks(func_nodes, name, arity)
      else
        [func] = func_nodes
        build_single_function_blocks(func, graph)
      end

    %{
      id: to_string(hd(func_nodes).id),
      name: to_string(name),
      arity: arity,
      blocks: %{blocks: blocks, edges: edges}
    }
  end

  defp build_multi_clause_blocks(func_nodes, name, arity) do
    blocks =
      func_nodes
      |> Enum.with_index()
      |> Enum.map(fn {func, idx} ->
        source = extract_source(func)
        start_line = get_span_field(func, :start_line) || 1
        pattern = extract_pattern(func)

        %{
          id: to_string(func.id),
          label: "#{name}/#{arity} (clause #{idx + 1}: #{pattern})",
          start_line: start_line,
          lines: if(source, do: String.split(source, "\n"), else: []),
          source_html: highlight(source)
        }
      end)

    dispatch_id = "dispatch_#{hd(func_nodes).id}"

    dispatch_block = %{
      id: dispatch_id,
      label: "#{name}/#{arity} dispatch",
      start_line: get_span_field(hd(func_nodes), :start_line) || 1,
      lines: ["# pattern match dispatch"],
      source_html: nil
    }

    edges =
      func_nodes
      |> Enum.with_index()
      |> Enum.map(fn {func, idx} ->
        %{
          id: "dispatch_#{func.id}_#{idx}",
          source: dispatch_id,
          target: to_string(func.id),
          label: extract_pattern(func),
          color: "#16a34a"
        }
      end)

    {[dispatch_block | blocks], edges}
  end

  defp build_single_function_blocks(func, graph) do
    start_line = get_span_field(func, :start_line) || 1

    # Check for multi-clause function (multiple function_clause children)
    function_clauses =
      func.children
      |> Enum.filter(&(&1.type == :clause and &1.meta[:kind] == :function_clause))

    if length(function_clauses) > 1 do
      build_function_clause_dispatch(func, function_clauses)
    else
      build_function_with_branching(func, graph, start_line)
    end
  end

  defp build_function_clause_dispatch(func, clauses) do
    # Each clause becomes a block, dispatch node connects to all
    clause_blocks =
      clauses
      |> Enum.with_index()
      |> Enum.map(fn {clause, idx} ->
        # Extract source for this clause from file
        clause_start =
          get_span_field(clause, :start_line) || get_span_field(func, :start_line) || 1

        clause_source = extract_clause_range_source(func, clause, clauses)
        pattern = extract_clause_pattern(clause)

        %{
          id: to_string(clause.id),
          label: "#{func.meta[:name]}/#{func.meta[:arity]} clause #{idx + 1}: #{pattern}",
          start_line: clause_start,
          lines: if(clause_source, do: String.split(clause_source, "\n"), else: [pattern]),
          source_html: highlight(clause_source)
        }
      end)

    edges =
      clauses
      |> Enum.with_index()
      |> Enum.map(fn {clause, idx} ->
        %{
          id: "dispatch_#{func.id}_#{clause.id}",
          source: to_string(func.id),
          target: to_string(clause.id),
          label: extract_clause_pattern(clause),
          color: dispatch_color(idx)
        }
      end)

    # Dispatch entry block (just the function name)
    dispatch = %{
      id: to_string(func.id),
      label: "#{func.meta[:name]}/#{func.meta[:arity]} dispatch",
      start_line: get_span_field(func, :start_line) || 1,
      lines: ["pattern match dispatch"],
      source_html: nil
    }

    {[dispatch | clause_blocks], edges}
  end

  defp dispatch_color(0), do: "#16a34a"
  defp dispatch_color(1), do: "#2563eb"
  defp dispatch_color(2), do: "#ea580c"
  defp dispatch_color(_), do: "#7c3aed"

  defp extract_clause_range_source(func, clause, all_clauses) do
    file = get_span_field(func, :file)
    clause_start = get_span_field(clause, :start_line)

    with true <- is_binary(file) and is_integer(clause_start),
         end_line <- clause_end_line(func, clause_start, all_clauses),
         {:ok, content} <- File.read(file) do
      content
      |> String.split("\n")
      |> Enum.slice((clause_start - 1)..(end_line - 1))
      |> Enum.join("\n")
      |> format_source()
    else
      _ -> nil
    end
  end

  defp clause_end_line(func, clause_start, all_clauses) do
    next_start =
      all_clauses
      |> Enum.map(&(get_span_field(&1, :start_line) || 0))
      |> Enum.filter(&(&1 > clause_start))
      |> Enum.min(fn -> nil end)

    func_end =
      find_func_end_line(
        get_span_field(func, :file),
        get_span_field(func, :start_line) || 1
      )

    (next_start && next_start - 1) || func_end || clause_start + 10
  end

  defp find_func_end_line(file, start_line) do
    cache = Process.get(:reach_def_end_cache, %{})

    case Map.get(cache, file) do
      nil -> nil
      line_map -> Map.get(line_map, start_line)
    end
  end

  defp build_function_with_branching(func, graph, start_line) do
    all_func_nodes = IR.all_nodes(func)
    source = extract_source(func)

    branching_nodes =
      all_func_nodes
      |> Enum.filter(fn n ->
        n.type in [:case, :if, :cond] and n.id != func.id
      end)

    if branching_nodes == [] do
      entry = %{
        id: to_string(func.id),
        label: "#{func.meta[:name]}/#{func.meta[:arity]}",
        start_line: start_line,
        lines: if(source, do: String.split(source, "\n"), else: []),
        source_html: highlight(source)
      }

      {[entry], []}
    else
      build_branching_blocks(func, branching_nodes, graph, source, start_line)
    end
  end

  defp build_branching_blocks(func, branching_nodes, _graph, source, start_line) do
    entry = %{
      id: to_string(func.id),
      label: "#{func.meta[:name]}/#{func.meta[:arity]}",
      start_line: start_line,
      lines: if(source, do: String.split(source, "\n"), else: []),
      source_html: highlight(source)
    }

    clause_blocks =
      branching_nodes
      |> Enum.flat_map(fn branch_node ->
        branch_node.children
        |> Enum.filter(&(&1.type == :clause))
        |> Enum.with_index()
        |> Enum.map(fn {clause, _idx} ->
          clause_source = extract_clause_source(clause)
          clause_start = get_span_field(clause, :start_line) || start_line
          pattern = extract_clause_pattern(clause)

          %{
            id: to_string(clause.id),
            label: "#{branch_label(branch_node.type)} #{pattern}",
            start_line: clause_start,
            lines: if(clause_source, do: String.split(clause_source, "\n"), else: [pattern]),
            source_html: highlight(clause_source)
          }
        end)
      end)

    edges =
      branching_nodes
      |> Enum.flat_map(fn branch_node ->
        branch_node.children
        |> Enum.filter(&(&1.type == :clause))
        |> Enum.with_index()
        |> Enum.map(fn {clause, idx} ->
          %{
            id: "br_#{func.id}_#{clause.id}",
            source: to_string(func.id),
            target: to_string(clause.id),
            label: extract_clause_pattern(clause),
            color: if(idx == 0, do: "#16a34a", else: "#ea580c")
          }
        end)
      end)

    {[entry | clause_blocks], edges}
  end

  defp branch_label(:case), do: "case"
  defp branch_label(:if), do: "if"
  defp branch_label(:cond), do: "cond"
  defp branch_label(:with), do: "with"
  defp branch_label(other), do: to_string(other)

  defp extract_pattern(func_node) do
    clauses = Enum.filter(func_node.children, &(&1.type == :clause))

    case clauses do
      [clause | _] ->
        clause.children
        |> Enum.filter(fn c ->
          c.meta[:binding_role] == :definition or
            c.type in [:literal, :tuple, :map, :list, :struct]
        end)
        |> Enum.map_join(", ", &pattern_to_string/1)
        |> case do
          "" -> "_"
          s -> s
        end

      _ ->
        "_"
    end
  end

  defp extract_clause_pattern(clause) do
    clause.children
    |> Enum.take_while(fn c ->
      c.meta[:binding_role] == :definition or
        c.type in [:literal, :tuple, :map, :list, :struct, :var]
    end)
    |> Enum.map_join(", ", &pattern_to_string/1)
    |> case do
      "" -> "_"
      s -> s
    end
  end

  defp pattern_to_string(%{type: :literal, meta: %{value: val}}), do: inspect(val)
  defp pattern_to_string(%{type: :var, meta: %{name: name}}), do: to_string(name)
  defp pattern_to_string(%{type: :tuple}), do: "{...}"
  defp pattern_to_string(%{type: :map}), do: "%{...}"
  defp pattern_to_string(%{type: :list}), do: "[...]"
  defp pattern_to_string(%{type: :struct, meta: %{name: name}}), do: "%#{inspect(name)}{}"
  defp pattern_to_string(_), do: "_"

  defp extract_source(func_node) do
    Reach.Visualize.extract_func_source(func_node)
  end

  defp extract_clause_source(%{source_span: %{file: file, start_line: start}} = _clause)
       when is_binary(file) and is_integer(start) do
    # Find the end of this clause — next sibling clause or parent's end
    case File.read(file) do
      {:ok, content} ->
        lines = String.split(content, "\n")
        # Take lines from clause start, heuristic: up to next clause or end
        clause_lines =
          lines
          |> Enum.drop(start - 1)
          |> Enum.take_while(fn line ->
            trimmed = String.trim(line)
            trimmed != "" and trimmed != "end"
          end)

        if clause_lines != [] do
          clause_lines
          |> Enum.join("\n")
          |> format_source()
        else
          nil
        end

      _ ->
        nil
    end
  end

  defp extract_clause_source(_), do: nil

  defp format_source(source) do
    Code.format_string!(source) |> IO.iodata_to_binary()
  rescue
    _ -> String.trim(source)
  end

  defp highlight(nil), do: nil

  defp highlight(source) do
    if Code.ensure_loaded?(Makeup) do
      source
      |> Makeup.highlight()
      |> String.replace(~r{^<pre class="highlight"><code>}, "")
      |> String.replace(~r{</code></pre>$}, "")
    else
      nil
    end
  end

  defp get_span_field(%{source_span: %{} = span}, field), do: Map.get(span, field)
  defp get_span_field(_, _), do: nil
end
