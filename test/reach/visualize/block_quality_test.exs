defmodule Reach.Visualize.BlockQualityTest do
  use ExUnit.Case, async: true

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
      {:error, _} ->
        []

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

  defp audit_function(func, module, _all_ir_nodes, file) do
    name = "#{module}.#{func["name"]}/#{func["arity"]}"
    nodes = func["nodes"]
    source_lines = file && read_lines(file)

    func_start = find_entry_end(nodes)
    func_end = find_exit_start(nodes)

    []
    # R1: Every source line of function body appears in at least one block
    |> check_coverage(name, nodes, func_start, func_end, source_lines)
    # R2: No two blocks share the same source line range (excluding entry/exit overlap)
    |> check_disjointness(name, nodes)
    # R5: No empty blocks — every non-entry/exit block has source_html
    |> check_source_html(name, nodes)
    # R6: No nil labels
    |> check_labels(name, nodes)
    # R7: Entry/exit structure
    |> check_entry_exit(name, nodes)
  end

  # R1: Coverage — every line between def and end should appear in some block.
  # Allow ≤5 missing lines per function (compiler limitation with pipe chains and heredocs).
  defp check_coverage(violations, _name, _nodes, _func_start, _func_end, nil), do: violations

  defp check_coverage(violations, _name, _nodes, func_start, func_end, _source_lines)
       when is_nil(func_start) or is_nil(func_end),
       do: violations

  defp check_coverage(violations, name, nodes, func_start, func_end, source_lines) do
    body_blocks = Enum.reject(nodes, &(&1["type"] == "exit"))
    covered_lines = collect_covered_lines(body_blocks, nodes)
    expected_lines = collect_expected_lines(func_start, func_end, source_lines)
    missing = MapSet.difference(expected_lines, covered_lines)

    missing_list = missing |> MapSet.to_list() |> Enum.sort()

    if length(missing_list) > 5 do
      [{:coverage, name, "missing lines: #{Enum.join(missing_list, ", ")}"} | violations]
    else
      violations
    end
  end

  # Issue #9: build MapSet once, conditionally add exit line
  defp collect_covered_lines(body_blocks, nodes) do
    lines_set =
      body_blocks
      |> Enum.flat_map(fn b ->
        s = b["start_line"]
        e = b["end_line"]
        if s && e && s > 0 && e >= s, do: Range.new(s, e), else: []
      end)
      |> MapSet.new()

    exit_line =
      case Enum.find(nodes, &(&1["type"] == "exit")) do
        %{"start_line" => l} when is_integer(l) -> l
        _ -> nil
      end

    if exit_line, do: MapSet.put(lines_set, exit_line), else: lines_set
  end

  defp collect_expected_lines(func_start, func_end, source_lines) do
    Range.new(func_start, func_end)
    |> Enum.filter(fn l ->
      line = Enum.at(source_lines, l - 1, "")
      trimmed = String.trim(line)
      trimmed != "" and not String.starts_with?(trimmed, "#")
    end)
    |> MapSet.new()
  end

  # R2: No overlapping blocks (except entry shares def line)
  defp check_disjointness(violations, name, nodes) do
    body_blocks =
      Enum.filter(nodes, fn n ->
        n["type"] not in ["entry", "exit"] and
          n["start_line"] != nil and n["end_line"] != nil
      end)

    overlaps =
      for b1 <- body_blocks, b2 <- body_blocks, b1["id"] < b2["id"] do
        if ranges_overlap?(
             b1["start_line"],
             b1["end_line"],
             b2["start_line"],
             b2["end_line"]
           ) do
          {b1["id"], b2["id"], "#{b1["start_line"]}-#{b1["end_line"]}",
           "#{b2["start_line"]}-#{b2["end_line"]}"}
        end
      end
      |> Enum.reject(&is_nil/1)

    for {id1, id2, r1, r2} <- overlaps do
      {:disjointness, name, "overlapping blocks #{id1} (#{r1}) and #{id2} (#{r2})"}
    end ++ violations
  end

  # R5: No empty blocks
  defp check_source_html(violations, name, nodes) do
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

    has_clause = Enum.any?(nodes, &(&1["type"] == "clause"))
    has_branch = Enum.any?(nodes, &(&1["type"] in ["branch", "sequential"]))

    if has_branch and not has_clause do
      if length(exits) != 1 do
        [
          {:entry_exit, name, "expected 1 exit for CFG function, got #{length(exits)}"}
          | violations
        ]
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
