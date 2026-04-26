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

  test "reach.inspect emits graph-backed candidates as json" do
    output =
      capture_io(fn ->
        Inspect.run(["Reach.Frontend.Elixir.translate/3", "--candidates", "--format", "json"])
      end)

    json =
      output
      |> String.split("\n")
      |> Enum.drop_while(&(not String.starts_with?(&1, "{")))
      |> Enum.join("\n")

    assert {:ok, data} = Jason.decode(json)
    assert data["target"] == "Reach.Frontend.Elixir.translate/3"
    assert Enum.any?(data["candidates"], &(&1["kind"] == "extract_pure_region"))
  end

  test "reach.inspect emits consolidated context json" do
    output =
      capture_io(fn -> Inspect.run(["Reach.to_dot/1", "--context", "--format", "json"]) end)

    json =
      output
      |> String.split("\n")
      |> Enum.drop_while(&(not String.starts_with?(&1, "{")))
      |> Enum.join("\n")

    assert {:ok, data} = Jason.decode(json)
    assert data["command"] == "reach.inspect"
    assert data["target"] == "Reach.to_dot/1"
    assert is_map(data["deps"])
    assert is_map(data["data"])
  end

  test "reach.trace delegates variable tracing" do
    output =
      capture_io(fn ->
        Trace.run(["--variable", "graph", "--in", "Reach.to_dot/1", "--format", "oneline"])
      end)

    assert output =~ "graph"
  end

  test "reach.check emits graph-backed candidates as json" do
    output = capture_io(fn -> Check.run(["--candidates", "--format", "json"]) end)

    json =
      output
      |> String.split("\n")
      |> Enum.drop_while(&(not String.starts_with?(&1, "{")))
      |> Enum.join("\n")

    assert {:ok, data} = Jason.decode(json)
    assert is_list(data["candidates"])
    assert Enum.any?(data["candidates"], &(&1["kind"] in ["break_cycle", "isolate_effects"]))
  end

  test "reach.check validates an empty architecture policy" do
    File.write!(".reach.exs", "[layers: [cli: \"Mix.Tasks.*\", core: \"Reach.*\"]]")
    on_exit(fn -> File.rm(".reach.exs") end)

    output = capture_io(fn -> Check.run(["--arch", "--format", "json"]) end)

    json =
      output
      |> String.split("\n")
      |> Enum.drop_while(&(not String.starts_with?(&1, "{")))
      |> Enum.join("\n")

    assert {:ok, data} = Jason.decode(json)
    assert data["status"] == "ok"
    assert data["violations"] == []
  end

  test "reach.check changed mode reports files and functions" do
    output =
      capture_io(fn -> Check.run(["--changed", "--base", "HEAD", "--format", "json"]) end)

    json =
      output
      |> String.split("\n")
      |> Enum.drop_while(&(not String.starts_with?(&1, "{")))
      |> Enum.join("\n")

    assert {:ok, data} = Jason.decode(json)
    assert is_list(data["changed_files"])
    assert is_list(data["changed_functions"])
  end
end
