defmodule Mix.Tasks.Reach.CanonicalTest do
  use ExUnit.Case

  import ExUnit.CaptureIO

  alias Mix.Tasks.Reach.Check
  alias Mix.Tasks.Reach.Inspect
  alias Mix.Tasks.Reach.Map
  alias Mix.Tasks.Reach.Trace

  test "reach.map delegates to selected project summaries" do
    output = capture_io(fn -> Map.run(["--hotspots", "--top", "1", "--format", "oneline"]) end)

    assert output =~ "score="
  end

  test "reach.inspect emits candidate placeholder as json" do
    output =
      capture_io(fn -> Inspect.run(["Reach.to_dot/1", "--candidates", "--format", "json"]) end)

    assert {:ok, data} = Jason.decode(output)
    assert data["target"] == "Reach.to_dot/1"
    assert data["candidates"] == []
  end

  test "reach.trace delegates variable tracing" do
    output =
      capture_io(fn ->
        Trace.run(["--variable", "graph", "--in", "Reach.to_dot/1", "--format", "oneline"])
      end)

    assert output =~ "graph"
  end

  test "reach.check emits candidate placeholder as json" do
    output = capture_io(fn -> Check.run(["--candidates", "--format", "json"]) end)

    assert {:ok, data} = Jason.decode(output)
    assert data["candidates"] == []
  end
end
