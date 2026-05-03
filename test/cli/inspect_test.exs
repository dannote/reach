defmodule Reach.CLI.InspectTest do
  use ExUnit.Case

  import ExUnit.CaptureIO

  alias Mix.Tasks.Reach.Inspect

  test "reach.inspect preserves call graph rendering option" do
    output = capture_io(fn -> Inspect.run(["Reach.to_dot/1", "--call-graph"]) end)

    assert output =~ "to_dot/1"
  end

  test "reach.inspect explains module dependency paths" do
    output = capture_io(fn -> Inspect.run(["Reach.CLI.Project", "--why", "Reach.Project"]) end)

    assert output =~ "module_dependency_path"
    assert output =~ "Reach.CLI.Project"
    assert output =~ "Reach.Project"
  end
end
