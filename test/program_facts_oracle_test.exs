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

  @data_flow_policies [
    :straight_line_data_flow,
    :assignment_chain,
    :branch_data_flow,
    :helper_call_data_flow,
    :pipeline_data_flow,
    :return_data_flow
  ]

  @effect_policies [:pure, :io_effect, :send_effect, :raise_effect, :read_effect, :write_effect]

  @branch_policies [
    :if_else,
    :case_clauses,
    :cond_branches,
    :with_chain,
    :anonymous_fn_branch,
    :multi_clause_function,
    :nested_branches
  ]

  @syntax_policies [
    :guard_clause,
    :try_rescue_after,
    :receive_message,
    :comprehension,
    :struct_update,
    :default_arguments
  ]

  @architecture_policies [
    :layered_valid,
    :forbidden_dependency,
    :layer_cycle,
    :public_api_boundary_violation,
    :internal_boundary_violation,
    :allowed_effect_violation
  ]

  test "direct API discovers generated call graph oracle edges" do
    for {policy, index} <- Enum.with_index(@call_graph_policies, 1) do
      program = ProgramFacts.generate!(policy: policy, seed: 1_300 + index, depth: 4, width: 3)

      Assertions.assert_modules_discovered(program)
      Assertions.assert_call_edges_discovered(program)
    end
  end

  test "direct API exposes generated data-flow oracle variables and sinks" do
    for {policy, index} <- Enum.with_index(@data_flow_policies, 1) do
      program = ProgramFacts.generate!(policy: policy, seed: 1_700 + index)

      Assertions.assert_modules_discovered(program)
      Assertions.assert_data_flow_visible(program)
    end
  end

  test "direct API discovers generated effect oracle facts" do
    for {policy, index} <- Enum.with_index(@effect_policies, 1) do
      program = ProgramFacts.generate!(policy: policy, seed: 1_500 + index)

      Assertions.assert_modules_discovered(program)
      Assertions.assert_effects_discovered(program)
    end
  end

  test "direct API exposes generated branch and clause oracle facts" do
    for {policy, index} <- Enum.with_index(@branch_policies, 1) do
      program = ProgramFacts.generate!(policy: policy, seed: 1_800 + index)

      Assertions.assert_modules_discovered(program)
      Assertions.assert_branches_visible(program)
    end
  end

  test "direct API exposes generated syntax oracle facts" do
    for {policy, index} <- Enum.with_index(@syntax_policies, 1) do
      program = ProgramFacts.generate!(policy: policy, seed: 1_900 + index)

      Assertions.assert_modules_discovered(program)
      Assertions.assert_syntax_visible(program)
    end
  end

  test "architecture CLI contract reports generated architecture oracle facts" do
    for {policy, index} <- Enum.with_index(@architecture_policies, 1) do
      program = ProgramFacts.generate!(policy: policy, seed: 1_600 + index)

      Assertions.assert_architecture_policy(program)
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
