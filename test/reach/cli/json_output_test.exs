defmodule Reach.CLI.JSONOutputTest do
  use ExUnit.Case

  import ExUnit.CaptureIO

  alias Mix.Tasks.Reach.Check
  alias Mix.Tasks.Reach.Inspect
  alias Mix.Tasks.Reach.Map

  test "reach.map emits a consolidated json envelope" do
    output = capture_io(fn -> Map.run(["--format", "json", "--top", "2"]) end)

    assert String.starts_with?(output, "{")
    assert {:ok, data} = Jason.decode(output)
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

  test "reach.inspect explains why one target reaches another" do
    output =
      capture_io(fn ->
        Inspect.run([
          "to_dot/1",
          "--why",
          "Graph.to_dot/1",
          "--format",
          "json"
        ])
      end)

    assert String.starts_with?(output, "{")
    assert {:ok, data} = Jason.decode(output)
    assert data["command"] == "reach.inspect"
    assert data["relation"] == "call_path"
    assert [%{"kind" => "call", "nodes" => nodes, "evidence" => evidence}] = data["paths"]
    assert Enum.any?(nodes, &(&1["function"] =~ "to_dot/1"))
    assert Enum.any?(evidence, &(&1["call"] =~ "Graph.to_dot"))
  end

  test "reach.check emits graph-backed candidates as pure json" do
    output = capture_io(fn -> Check.run(["--candidates", "--format", "json"]) end)

    assert {:ok, data} = Jason.decode(output)
    assert is_list(data["candidates"])

    assert Enum.any?(
             data["candidates"],
             &(&1["kind"] in ["break_cycle", "isolate_effects", "extract_pure_region"])
           )

    assert Enum.all?(data["candidates"], &:maps.is_key("confidence", &1))
    assert Enum.all?(data["candidates"], &:maps.is_key("proof", &1))
  end
end
