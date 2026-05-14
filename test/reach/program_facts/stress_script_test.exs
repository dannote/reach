defmodule Reach.ProgramFactsStressScriptTest do
  use ExUnit.Case

  @tag timeout: 120_000
  test "ProgramFacts stress script runs with a small iteration count" do
    {output, status} =
      System.cmd(
        "mix",
        ["run", "scripts/program_facts_stress.exs"],
        env: [
          {"MIX_ENV", "test"},
          {"PROGRAM_FACTS_STRESS_ITERATIONS", "2"},
          {"PROGRAM_FACTS_STRESS_SEED", "8100"},
          {"PROGRAM_FACTS_FAILURE_ROOT", Path.join(System.tmp_dir!(), "reach-pf-stress-test")}
        ],
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert output =~ "ProgramFacts stress completed successfully"
  end
end
