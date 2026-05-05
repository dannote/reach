defmodule Reach.ProgramFactsCloneConsistencyFuzzTest do
  use ExUnit.Case
  use ExUnitProperties

  alias Reach.Check.Smells
  alias Reach.Test.ProgramFacts.Project, as: PFProject

  @clone_policies [
    :linear_call_chain,
    :assignment_chain,
    :pipeline_data_flow,
    :pure,
    :read_effect,
    :write_effect
  ]

  @tag timeout: 120_000
  property "clone-backed smell checks tolerate transformed generated programs" do
    check all(
            program <-
              ProgramFacts.StreamData.program(
                policies: @clone_policies,
                seed_range: 500..540,
                depth_range: 2..5,
                width_range: 2..4
              ),
            transform <-
              StreamData.member_of([:add_dead_pure_statement, :reorder_independent_assignments]),
            max_runs: 12
          ) do
      program = ProgramFacts.Transform.apply!(program, transform)

      PFProject.with_project(program, fn _dir, project ->
        findings = Smells.run(project, clone_analysis: [min_mass: 3, min_similarity: 0.5])

        assert is_list(findings)
        refute Enum.any?(findings, &(&1.kind == :ex_dna))
      end)
    end
  end
end
