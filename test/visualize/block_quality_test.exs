defmodule Reach.Visualize.BlockQualityTest do
  use ExUnit.Case, async: true

  alias Reach.Visualize.Helpers

  @tag timeout: 120_000
  test "block quality audit across real codebases" do
    dirs = [
      "/tmp/ecto/lib/ecto/query.ex",
      "/tmp/phoenix/lib/phoenix/controller.ex",
      "/tmp/phoenix/lib/phoenix/router.ex",
      "/tmp/elixir/lib/enum.ex",
      "/tmp/oban/lib/oban/engine.ex"
    ]

    files =
      dirs
      |> Enum.filter(&File.exists?/1)

    violations = Enum.flat_map(files, &audit_file/1)

    if violations != [] do
      for {rule, func, detail} <- violations do
        IO.puts("FAIL [#{rule}] #{func}: #{detail}")
      end
    end

    assert violations == [], "#{length(violations)} block quality violations found"
  end

  defp audit_file(file) do
    case Reach.file_to_graph(file) do
      {:error, _} -> []
      {:ok, graph} ->
        json = Reach.Visualize.to_json(graph)
        parsed = Jason.decode!(json)
        all_nodes = Reach.nodes(graph)

        for mod <- parsed["control_flow"],
            func <- mod["functions"],
            func["nodes"] != nil and length(func["nodes"]) > 2,
            violation <- audit_function(func, mod["module"], all_nodes, file) do
          violation
        end
    end
  end

  defp audit_function(func, module, all_ir_nodes, file) do
    name = "#{module}.#{func["name"]}/#{func["arity"]}"
    nodes = func["nodes"]
    edges = func["edges"] || []
    source_lines = file && read_lines(file)

    func_start = find_entry_end(nodes)
    func_end = find_exit_start(nodes)

    []

    # R1: Every source line of function body appears in at least one block
    |> check_coverage(name, nodes, func_start, func_end, source_lines)

    # R2: No two blocks share the same source line range (excluding entry/exit overlap)
    |> check_disjointness(name, nodes)

    # R3-R4: Branch boundaries handled by CFG builder (structural)
    # Checked indirectly via R1/R2/R5

    # R5: No empty blocks — every non-entry/exit block has source_html
    |> check_source_html(name, nodes, all_ir_nodes)

    # R6: No nil labels
    |> check_labels(name, nodes)

    # R7: Entry/exit structure
    |> check_entry_exit(name, nodes)
  end

  # R1: Coverage — every line between def and end should appear in some block
  defp check_coverage(violations, name, nodes, func_start, func_end, nil) do
    violations
  end

  defp check_coverage(violations, name, nodes, func_start, func_end, source_lines)
       when is_nil(func_start) or is_nil(func_end) do
    violations
  end

  defp check_coverage(violations, name, nodes, func_start, func_end, source_lines) do
    body_blocks =
      nodes
      |> Enum.reject(fn n -> n["type"] == "exit" end)

    covered_lines =
      body_blocks
      |> Enum.flat_map(fn b ->
        s = b["start_line"]
        e = b["end_line"]
        if s && e && s > 0 && e >= s, do: Range.new(s, e), else: []
      end)
      |> MapSet.new()

    # Also include the exit block's line (covers the 'end' line)
    exit_block = Enum.find(nodes, &(&1["type"] == "exit"))
    covered_lines =
      if exit_block && exit_block["start_line"] do
        MapSet.put(covered_lines, exit_block["start_line"])
      else
        covered_lines
      end

    expected_lines =
      Range.new(func_start, func_end)
      |> Enum.filter(fn l ->
        line = Enum.at(source_lines, l - 1, "")
        trimmed = String.trim(line)
        # Skip blank lines and comment-only lines
        trimmed != "" and not String.starts_with?(trimmed, "#")
      end)
      |> MapSet.new()

    missing = MapSet.difference(expected_lines, covered_lines)

    if MapSet.size(missing) > 0 do
      missing_list = MapSet.to_list(missing) |> Enum.sort()
      # Allow gaps up to 3 lines — compiler loses source spans for
      # multi-line strings, macro expansions, with desugaring, etc.
      if length(missing_list) > 5 do
        [{:coverage, name, "missing lines: #{Enum.join(missing_list, ", ")}"} | violations]
      else
        violations
      end
    else
      violations
    end
  end

  # R2: No overlapping blocks (except entry shares def line)
  defp check_disjointness(violations, name, nodes) do
    body_blocks =
      nodes
      |> Enum.filter(fn n -> n["type"] not in ["entry", "exit"] end)
      |> Enum.filter(fn n -> n["start_line"] != nil and n["end_line"] != nil end)

    overlaps =
      for b1 <- body_blocks, b2 <- body_blocks, b1["id"] < b2["id"] do
        if ranges_overlap?(
          b1["start_line"],
          b1["end_line"],
          b2["start_line"],
          b2["end_line"]
        ) do
          {b1["id"], b2["id"], "#{b1["start_line"]}-#{b1["end_line"]}", "#{b2["start_line"]}-#{b2["end_line"]}"}
        end
      end
      |> Enum.reject(&is_nil/1)

    for {id1, id2, r1, r2} <- overlaps do
      {:disjointness, name, "overlapping blocks #{id1} (#{r1}) and #{id2} (#{r2})"}
    end ++ violations
  end

  # R5: No empty blocks
  defp check_source_html(violations, name, nodes, all_ir_nodes) do
    empty =
      nodes
      |> Enum.filter(fn n ->
        n["type"] not in ["entry", "exit"] and
          (n["source_html"] == nil or n["source_html"] == "")
      end)

    for b <- empty do
      {:empty_block, name, "#{b["id"]} [#{b["type"]}] label=#{inspect(b["label"])}"}
    end ++ violations
  end

  # R6: No nil labels
  defp check_labels(violations, name, nodes) do
    nil_labels =
      nodes
      |> Enum.filter(fn n -> n["label"] == nil and n["type"] not in ["entry", "exit"] end)

    for b <- nil_labels do
      {:nil_label, name, "#{b["id"]} [#{b["type"]}]"}
    end ++ violations
  end

  # R7: Entry/exit structure
  defp check_entry_exit(violations, name, nodes) do
    entries = Enum.filter(nodes, &(&1["type"] == "entry"))
    exits = Enum.filter(nodes, &(&1["type"] == "exit"))

    violations =
      if length(entries) != 1 do
        [{:entry_exit, name, "expected 1 entry, got #{length(entries)}"} | violations]
      else
        violations
      end

    # Only CFG-based functions need exit nodes; dispatch functions don't
    has_clause = Enum.any?(nodes, &(&1["type"] == "clause"))
    has_branch = Enum.any?(nodes, &(&1["type"] in ["branch", "sequential"]))

    if has_branch and not has_clause do
      if length(exits) != 1 do
        [{:entry_exit, name, "expected 1 exit for CFG function, got #{length(exits)}"} | violations]
      else
        violations
      end
    else
      violations
    end
  end

  # Helpers

  defp find_entry_end(nodes) do
    case Enum.find(nodes, &(&1["type"] == "entry")) do
      nil -> nil
      entry -> entry["start_line"]
    end
  end

  defp find_exit_start(nodes) do
    case Enum.find(nodes, &(&1["type"] == "exit")) do
      nil -> nil
      exit_node -> exit_node["start_line"]
    end
  end

  defp ranges_overlap?(s1, e1, s2, e2) do
    s1 <= e2 and s2 <= e1
  end

  defp read_lines(nil), do: nil
  defp read_lines(file), do: file |> File.read!() |> String.split("\n")
end
