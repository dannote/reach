defmodule Reach.CLI.TraceTest do
  use ExUnit.Case

  import ExUnit.CaptureIO

  alias Mix.Tasks.Reach.Trace

  test "reach.trace runs variable tracing directly" do
    output =
      capture_io(fn ->
        Trace.run(["--variable", "graph", "--in", "Reach.to_dot/1", "--format", "oneline"])
      end)

    assert output =~ "graph"
  end
end
