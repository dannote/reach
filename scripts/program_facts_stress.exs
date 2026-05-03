defmodule Reach.ProgramFactsStress do
  @moduledoc false

  alias Mix.Tasks.Reach.{Check, Map, Trace}
  alias Reach.Test.ProgramFacts.Project, as: PFProject

  def run do
    Mix.Task.run("app.start")

    Code.require_file("test_helpers/reach/test/program_facts/project.ex", File.cwd!())

    iterations =
      System.get_env("PROGRAM_FACTS_STRESS_ITERATIONS", "100")
      |> String.to_integer()

    seed =
      System.get_env("PROGRAM_FACTS_STRESS_SEED", "7000")
      |> String.to_integer()

    failure_root =
      System.get_env(
        "PROGRAM_FACTS_FAILURE_ROOT",
        Path.join(System.tmp_dir!(), "reach-program-facts-failures")
      )

    File.mkdir_p!(failure_root)

    search =
      ProgramFacts.Search.run(
        iterations: iterations,
        seed: seed,
        policies: ProgramFacts.policies(),
        layouts: ProgramFacts.layouts(),
        scoring: [:new_features, :graph_complexity, :cycles, :long_paths]
      )

    IO.puts(
      "ProgramFacts stress: candidates=#{search.coverage.candidate_count} kept=#{search.coverage.program_count} features=#{search.coverage.feature_count}"
    )

    Enum.each(search.programs, &run_program!(&1, failure_root))

    IO.puts("ProgramFacts stress completed successfully")
  end

  defp run_program!(program, failure_root) do
    try do
      PFProject.with_project(program, fn _dir, _project ->
        Enum.each(commands(), fn {task, args, expected_command} ->
          data =
            ExUnit.CaptureIO.capture_io(fn -> task.run(args) end)
            |> String.split("\n")
            |> Enum.drop_while(&(not String.starts_with?(&1, "{")))
            |> Enum.join("\n")
            |> Jason.decode!()

          unless data["command"] == expected_command do
            raise "expected #{expected_command}, got #{inspect(data["command"])} for #{inspect(args)}"
          end
        end)
      end)
    rescue
      exception ->
        save_failure!(failure_root, program, exception, __STACKTRACE__)
        reraise exception, __STACKTRACE__
    end
  end

  defp commands do
    [
      {Map, ["--format", "json"], "reach.map"},
      {Map, ["--effects", "--format", "json"], "reach.map"},
      {Map, ["--depth", "--format", "json", "--top", "20"], "reach.map"},
      {Trace, ["--variable", "input", "--format", "json"], "reach.trace"},
      {Check, ["--smells", "--format", "json"], "reach.check"},
      {Check, ["--candidates", "--format", "json", "--top", "10"], "reach.check"}
    ]
  end

  defp save_failure!(root, program, exception, stacktrace) do
    dir =
      Path.join(
        root,
        "#{program.metadata.policy}-seed#{program.seed}-#{System.system_time(:millisecond)}"
      )

    ProgramFacts.Project.write!(dir, program, force: true)

    File.write!(
      Path.join(dir, "reach_failure.txt"),
      Exception.format(:error, exception, stacktrace) <>
        "\n\nReplay:\n  cd #{File.cwd!()} && PROGRAM_FACTS_FAILURE_ROOT=#{root} mix run scripts/program_facts_stress.exs\n"
    )

    IO.puts(:stderr, "saved ProgramFacts failure to #{dir}")
  end
end

Reach.ProgramFactsStress.run()
