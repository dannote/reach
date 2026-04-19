defmodule Mix.Tasks.GraphFlagTest do
  # Regression for https://github.com/dannote/reach/issues/6
  #
  # In 1.4.0, `mix reach.modules`, `mix reach.impact`, and `mix reach.slice`
  # crashed with `BadBooleanError` when `--graph` was not passed, because they
  # used strict `and` against `opts[:graph]` (which is `nil` for absent boolean
  # switches from OptionParser).
  use ExUnit.Case

  import ExUnit.CaptureIO

  test "mix reach.modules runs without --graph" do
    capture_io(fn ->
      assert :ok == (Mix.Tasks.Reach.Modules.run(["--format", "oneline"]) || :ok)
    end)
  end

  test "mix reach.impact runs without --graph" do
    capture_io(fn ->
      # Target a function that exists in reach itself
      assert :ok ==
               (Mix.Tasks.Reach.Impact.run([
                  "Reach.Project.from_mix_project/0",
                  "--format",
                  "oneline"
                ]) || :ok)
    end)
  end

  test "mix reach.slice runs without --graph" do
    capture_io(fn ->
      # Pick a known line in reach's own source — Project.load/1 def at line 6
      assert :ok ==
               (Mix.Tasks.Reach.Slice.run([
                  "lib/reach/cli/project.ex:6",
                  "--format",
                  "oneline"
                ]) || :ok)
    end)
  end
end
