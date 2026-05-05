defmodule Reach.ProgramFactsVisualizeFuzzTest do
  use ExUnit.Case
  use ExUnitProperties

  alias Reach.Test.ProgramFacts.Project, as: PFProject

  @visual_policies [
    :if_else,
    :case_clauses,
    :cond_branches,
    :with_chain,
    :anonymous_fn_branch,
    :multi_clause_function,
    :nested_branches,
    :try_rescue_after,
    :receive_message
  ]

  @tag timeout: 120_000
  property "generated branch-heavy programs produce valid visualization blocks" do
    check all(
            program <-
              ProgramFacts.StreamData.program(
                policies: @visual_policies,
                seed_range: 300..340,
                depth_range: 2..5,
                width_range: 2..4
              ),
            max_runs: 12
          ) do
      PFProject.with_project(program, fn _dir, _project ->
        program.files
        |> Enum.map(& &1.path)
        |> Enum.each(&assert_file_visualizes!/1)
      end)
    end
  end

  defp assert_file_visualizes!(file) do
    assert {:ok, graph} = Reach.file_to_graph(file)

    data =
      graph
      |> Reach.Visualize.to_json()
      |> Jason.decode!()

    for module <- data["control_flow"], function <- module["functions"] do
      assert function["nodes"] != []
      assert Enum.any?(function["nodes"], &(&1["type"] == "entry"))
      assert Enum.any?(function["nodes"], &(&1["type"] == "exit"))

      Enum.each(function["nodes"], &assert_visual_node!/1)

      assert_no_overlapping_ranges(function)
    end
  end

  defp assert_visual_node!(node) do
    assert is_binary(node["label"])
    assert node["label"] != ""

    if node["type"] not in ["entry", "exit"] do
      assert is_binary(node["source_html"])
      assert node["source_html"] != ""
    end
  end

  defp assert_no_overlapping_ranges(function) do
    ranges =
      function["nodes"]
      |> Enum.reject(&(&1["type"] in ["entry", "exit"]))
      |> Enum.flat_map(&line_range/1)

    duplicates =
      ranges
      |> Enum.frequencies()
      |> Enum.filter(fn {_line, count} -> count > 1 end)

    assert duplicates == [], "duplicate visualization source lines: #{inspect(duplicates)}"
  end

  defp line_range(%{"start_line" => start_line, "end_line" => end_line})
       when is_integer(start_line) and is_integer(end_line) and end_line >= start_line do
    Enum.to_list(start_line..end_line)
  end

  defp line_range(_node), do: []
end
