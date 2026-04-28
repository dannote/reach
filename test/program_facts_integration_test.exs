defmodule Reach.ProgramFactsIntegrationTest do
  use ExUnit.Case

  import ExUnit.CaptureIO

  alias Mix.Tasks.Reach.Inspect, as: ReachInspect
  alias Mix.Tasks.Reach.Map, as: ReachMap

  @call_path_policies [
    :single_call,
    :linear_call_chain,
    :branching_call_graph,
    :module_dependency_chain,
    :module_cycle
  ]

  @layout_policies [:plain, :umbrella, :package_style]
  @effect_policies [:pure, :io_effect, :send_effect, :raise_effect, :read_effect, :write_effect]

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

  test "generated effect policies are visible in reach.map --effects json", %{root: root} do
    for {policy, index} <- Enum.with_index(@effect_policies, 1) do
      program = ProgramFacts.generate!(policy: policy, seed: 700 + index)
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
end
