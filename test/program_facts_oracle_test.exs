defmodule Reach.ProgramFactsOracleTest do
  use ExUnit.Case
  use ExUnitProperties

  alias Reach.Test.ProgramFacts.Assertions

  @call_graph_policies [
    :single_call,
    :linear_call_chain,
    :branching_call_graph,
    :module_dependency_chain,
    :module_cycle
  ]

  @layout_policies [:plain, :umbrella, :package_style]
  @effect_policies [:pure, :io_effect, :send_effect, :raise_effect, :read_effect, :write_effect]

  test "direct API discovers generated call graph oracle edges" do
    for {policy, index} <- Enum.with_index(@call_graph_policies, 1) do
      program = ProgramFacts.generate!(policy: policy, seed: 1_300 + index, depth: 4, width: 3)

      Assertions.assert_modules_discovered(program)
      Assertions.assert_call_edges_discovered(program)
    end
  end

  test "direct API discovers generated effect oracle facts" do
    for {policy, index} <- Enum.with_index(@effect_policies, 1) do
      program = ProgramFacts.generate!(policy: policy, seed: 1_500 + index)

      Assertions.assert_modules_discovered(program)
      Assertions.assert_effects_discovered(program)
    end
  end

  test "direct API discovers generated modules across layouts" do
    for {layout, index} <- Enum.with_index(@layout_policies, 1) do
      program =
        ProgramFacts.generate!(
          policy: :linear_call_chain,
          seed: 1_400 + index,
          depth: 3,
          layout: layout
        )

      Assertions.assert_modules_discovered(program)
    end
  end

  property "direct API loads generated ProgramFacts oracle samples" do
    check all(
            program <-
              ProgramFacts.StreamData.program(
                policies: @call_graph_policies,
                seed_range: 1..30,
                depth_range: 2..4,
                width_range: 2..3
              ),
            max_runs: 8
          ) do
      Assertions.assert_modules_discovered(program)
      Assertions.assert_call_edges_discovered(program)
    end
  end
end
