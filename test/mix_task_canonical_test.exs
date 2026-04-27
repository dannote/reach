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

  test "reach.map emits a consolidated json envelope" do
    output = capture_io(fn -> Map.run(["--format", "json", "--top", "2"]) end)

    json =
      output
      |> String.split("\n")
      |> Enum.drop_while(&(not String.starts_with?(&1, "{")))
      |> Enum.join("\n")

    assert {:ok, data} = Jason.decode(json)
    assert data["command"] == "reach.map"
    assert is_map(data["summary"])
    assert is_map(data["sections"])
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

    assert Enum.any?(
             data["candidates"],
             &(&1["kind"] in ["break_cycle", "isolate_effects", "extract_pure_region"])
           )

    assert Enum.all?(data["candidates"], &:maps.is_key("confidence", &1))
    assert Enum.all?(data["candidates"], &:maps.is_key("proof", &1))
  end

  test "reach.check validates an empty architecture policy" do
    with_reach_config(~S([layers: [cli: "Mix.Tasks.*", core: "Reach.*"]]))

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

  test "reach.check reports architecture config errors" do
    with_reach_config("[unknown: true, layers: :bad]")

    assert_raise Mix.Error, ~r/Architecture policy failed/, fn ->
      capture_io(fn -> Check.run(["--arch", "--format", "json"]) end)
    end
  end

  test "reach.check reports public and internal boundary violations" do
    with_reach_config(~S([
        public_api: ["Reach"],
        internal: ["Reach.IR.*"],
        internal_callers: [{"Reach.IR.*", ["Reach.Project"]}]
      ]))

    assert_raise Mix.Error, ~r/Architecture policy failed/, fn ->
      capture_io(fn -> Check.run(["--arch", "--format", "json"]) end)
    end
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

  defp with_reach_config(contents) do
    previous = if File.exists?(".reach.exs"), do: File.read!(".reach.exs")
    File.write!(".reach.exs", contents)

    on_exit(fn ->
      if previous do
        File.write!(".reach.exs", previous)
      else
        File.rm(".reach.exs")
      end
    end)
  end
end
