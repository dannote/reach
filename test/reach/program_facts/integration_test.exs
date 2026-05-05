defmodule Reach.ProgramFactsIntegrationTest do
  use ExUnit.Case
  use ExUnitProperties

  import ExUnit.CaptureIO

  alias Mix.Tasks.Reach.Check, as: ReachCheck
  alias Mix.Tasks.Reach.Inspect, as: ReachInspect
  alias Mix.Tasks.Reach.Map, as: ReachMap
  alias Mix.Tasks.Reach.Trace, as: ReachTrace

  @call_path_policies [
    :single_call,
    :linear_call_chain,
    :branching_call_graph,
    :module_dependency_chain,
    :module_cycle
  ]

  @layout_policies [:plain, :umbrella, :package_style]

  @data_flow_policies [
    :straight_line_data_flow,
    :assignment_chain,
    :branch_data_flow,
    :helper_call_data_flow,
    :pipeline_data_flow,
    :return_data_flow
  ]

  @branch_policies [
    :if_else,
    :case_clauses,
    :cond_branches,
    :with_chain,
    :anonymous_fn_branch,
    :multi_clause_function,
    :nested_branches
  ]

  @effect_policies [:pure, :io_effect, :send_effect, :raise_effect, :read_effect, :write_effect]

  @architecture_policies [
    :layered_valid,
    :forbidden_dependency,
    :layer_cycle,
    :public_api_boundary_violation,
    :internal_boundary_violation,
    :allowed_effect_violation
  ]

  setup do
    root =
      Path.join(System.tmp_dir!(), "reach_program_facts_#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)

    on_exit(fn -> File.rm_rf!(root) end)

    {:ok, root: root}
  end

  test "generated call graph facts are explainable by reach.inspect --why", %{root: root} do
    for {policy, index} <- Enum.with_index(@call_path_policies, 1) do
      program = ProgramFacts.generate!(policy: policy, seed: 500 + index, depth: 4, width: 3)
      {_ok, dir, program} = ProgramFacts.Project.write_tmp!(program, root: root)
      [source, target | _rest] = source_target(program)

      data =
        in_project(dir, fn ->
          output =
            capture_io(fn ->
              ReachInspect.run([func_ref(source), "--why", func_ref(target), "--format", "json"])
            end)

          decode_json(output)
        end)

      assert data["command"] == "reach.inspect"
      assert data["relation"] == "call_path"
      assert data["paths"] != [], "expected #{inspect(policy)} to produce a call path"
    end
  end

  test "generated layouts are discovered and excluded fixtures are ignored", %{root: root} do
    for {layout, index} <- Enum.with_index(@layout_policies, 1) do
      program =
        ProgramFacts.generate!(
          policy: :linear_call_chain,
          seed: 600 + index,
          depth: 3,
          layout: layout
        )

      {_ok, dir, program} = ProgramFacts.Project.write_tmp!(program, root: root)

      project = in_project(dir, fn -> Reach.Project.from_mix_project() end)
      modules = MapSet.new(Map.keys(project.modules))

      assert MapSet.subset?(MapSet.new(program.facts.modules), modules)
      refute MapSet.member?(modules, Generated.ProgramFacts.Excluded)
    end
  end

  test "generated data-flow policies are visible in reach.map and reach.trace", %{root: root} do
    for {policy, index} <- Enum.with_index(@data_flow_policies, 1) do
      program = ProgramFacts.generate!(policy: policy, seed: 700 + index)
      {_ok, dir, _program} = ProgramFacts.Project.write_tmp!(program, root: root)

      {map_data, trace_data} =
        in_project(dir, fn ->
          map_output =
            capture_io(fn -> ReachMap.run(["--data", "--format", "json", "--top", "20"]) end)

          trace_output =
            capture_io(fn -> ReachTrace.run(["--variable", "input", "--format", "json"]) end)

          {decode_json(map_output), decode_json(trace_output)}
        end)

      assert get_in(map_data, ["sections", "data", "total_data_edges"]) > 0
      assert trace_data["command"] == "reach.trace"
      assert trace_data["definitions"] != []
      assert trace_data["uses"] != []
    end
  end

  test "generated branch policies are visible in reach.map --depth json", %{root: root} do
    for {policy, index} <- Enum.with_index(@branch_policies, 1) do
      program = ProgramFacts.generate!(policy: policy, seed: 800 + index)
      {_ok, dir, _program} = ProgramFacts.Project.write_tmp!(program, root: root)

      data =
        in_project(dir, fn ->
          output =
            capture_io(fn -> ReachMap.run(["--depth", "--format", "json", "--top", "20"]) end)

          decode_json(output)
        end)

      entry =
        data
        |> get_in(["sections", "depth"])
        |> Enum.find(&(&1["function"] == "entry/1"))

      assert entry, "expected #{inspect(policy)} to expose entry/1 in depth metrics"
      assert entry["depth"] > 0
      assert entry["clauses"] != []
    end
  end

  test "generated effect policies are visible in reach.map --effects json", %{root: root} do
    for {policy, index} <- Enum.with_index(@effect_policies, 1) do
      program = ProgramFacts.generate!(policy: policy, seed: 900 + index)
      {_ok, dir, _program} = ProgramFacts.Project.write_tmp!(program, root: root)

      data =
        in_project(dir, fn ->
          output = capture_io(fn -> ReachMap.run(["--effects", "--format", "json"]) end)
          decode_json(output)
        end)

      effects = get_in(data, ["summary", "effects"])
      assert is_map(effects)
      assert Map.has_key?(effects, expected_effect(policy))
    end
  end

  test "generated architecture policies are checked by reach.check --arch", %{root: root} do
    for {policy, index} <- Enum.with_index(@architecture_policies, 1) do
      program = ProgramFacts.generate!(policy: policy, seed: 1000 + index)
      {_ok, dir, _program} = ProgramFacts.Project.write_tmp!(program, root: root)

      output =
        in_project(dir, fn ->
          capture_io(fn ->
            if policy == :layered_valid do
              ReachCheck.run(["--arch", "--format", "json"])
            else
              assert_raise Mix.Error, ~r/Architecture policy failed/, fn ->
                ReachCheck.run(["--arch", "--format", "json"])
              end
            end
          end)
        end)

      data = decode_json(output)
      expected_type = expected_architecture_violation(policy)

      if expected_type do
        assert data["status"] == "failed"
        assert Enum.any?(data["violations"], &(&1["type"] == expected_type))
      else
        assert data["status"] == "ok"
        assert data["violations"] == []
      end
    end
  end

  test "generated candidate fixtures produce graph-backed candidates", %{root: root} do
    candidate_cases = [module_cycle: "break_cycle", mixed_effect_boundary: "isolate_effects"]

    for {{policy, expected_kind}, index} <- Enum.with_index(candidate_cases, 1) do
      program = ProgramFacts.generate!(policy: policy, seed: 1100 + index)
      {_ok, dir, _program} = ProgramFacts.Project.write_tmp!(program, root: root)

      data =
        in_project(dir, fn ->
          output =
            capture_io(fn ->
              ReachCheck.run(["--candidates", "--format", "json", "--top", "10"])
            end)

          decode_json(output)
        end)

      assert Enum.any?(data["candidates"], &(&1["kind"] == expected_kind))
    end
  end

  test "feedback-directed generated samples keep canonical JSON commands stable", %{root: root} do
    search =
      ProgramFacts.Search.run(
        iterations: 12,
        seed: 2_500,
        policies: ProgramFacts.policies(),
        layouts: @layout_policies,
        scoring: [:new_features, :graph_complexity, :cycles, :long_paths]
      )

    assert search.coverage.program_count > 0
    assert search.coverage.feature_count > 0

    for program <- Enum.take(search.programs, 6) do
      {_ok, dir, _program} = ProgramFacts.Project.write_tmp!(program, root: root)

      in_project(dir, fn ->
        assert_json_command(ReachMap, ["--format", "json"], "reach.map")
        assert_json_command(ReachMap, ["--effects", "--format", "json"], "reach.map")
        assert_json_command(ReachMap, ["--depth", "--format", "json", "--top", "10"], "reach.map")

        assert_json_command(
          ReachTrace,
          ["--variable", "input", "--format", "json"],
          "reach.trace"
        )

        assert_json_command(ReachCheck, ["--smells", "--format", "json"], "reach.check")

        assert_json_command(
          ReachCheck,
          ["--candidates", "--format", "json", "--top", "5"],
          "reach.check"
        )
      end)
    end
  end

  property "generated ProgramFacts samples can be loaded as Reach projects", %{root: root} do
    check all(
            program <-
              ProgramFacts.StreamData.program(
                seed_range: 0..20,
                depth_range: 2..4,
                width_range: 1..3
              ),
            max_runs: 5
          ) do
      {_ok, dir, program} = ProgramFacts.Project.write_tmp!(program, root: root)
      project = in_project(dir, fn -> Reach.Project.from_mix_project() end)
      modules = MapSet.new(Map.keys(project.modules))

      assert MapSet.subset?(MapSet.new(program.facts.modules), modules)
    end
  end

  defp source_target(program) do
    path = Enum.find(program.facts.call_paths, &(length(&1) >= 2))
    source = hd(path)
    target = Enum.at(path, 1)

    [source, target]
  end

  defp func_ref({module, function, arity}) do
    "#{inspect(module)}.#{function}/#{arity}"
  end

  defp in_project(dir, fun) do
    previous = File.cwd!()

    try do
      File.cd!(dir)
      fun.()
    after
      File.cd!(previous)
      Process.delete({Reach.CLI.Project, :func_index})
    end
  end

  defp assert_json_command(task, args, command) do
    output = capture_io(fn -> task.run(args) end)
    data = decode_json(output)
    assert data["command"] == command
    data
  end

  defp decode_json(output) do
    json =
      output
      |> String.split("\n")
      |> Enum.drop_while(&(not String.starts_with?(&1, "{")))
      |> Enum.join("\n")

    assert {:ok, data} = Jason.decode(json)
    data
  end

  defp expected_effect(:pure), do: "pure"
  defp expected_effect(:io_effect), do: "io"
  defp expected_effect(:send_effect), do: "send"
  defp expected_effect(:raise_effect), do: "exception"
  defp expected_effect(:read_effect), do: "read"
  defp expected_effect(:write_effect), do: "write"

  defp expected_architecture_violation(:layered_valid), do: nil
  defp expected_architecture_violation(:forbidden_dependency), do: "forbidden_dependency"
  defp expected_architecture_violation(:layer_cycle), do: "layer_cycle"
  defp expected_architecture_violation(:public_api_boundary_violation), do: "public_api_boundary"
  defp expected_architecture_violation(:internal_boundary_violation), do: "internal_boundary"
  defp expected_architecture_violation(:allowed_effect_violation), do: "effect_policy"
end
