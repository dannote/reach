defmodule Reach.CLI.CanonicalTasksTest do
  use ExUnit.Case

  import ExUnit.CaptureIO

  alias Mix.Tasks.Reach.Inspect
  alias Mix.Tasks.Reach.Map

  test "canonical commands call analyses directly and keep canonical json envelope" do
    output =
      capture_io(fn ->
        warning =
          capture_io(:stderr, fn ->
            Inspect.run(["Reach.to_dot/1", "--deps", "--format", "json"])
          end)

        assert warning == ""
      end)

    data = decode_json(output)
    assert data["command"] == "reach.inspect"
    assert data["tool"] == "reach.inspect"
  end

  test "reach.map delegates to selected project summaries" do
    output = capture_io(fn -> Map.run(["--hotspots", "--top", "1", "--format", "oneline"]) end)

    assert output =~ "score="
  end

  test "reach.map preserves legacy overview command options" do
    assert capture_io(fn -> Map.run(["--coupling", "--orphans", "--top", "2"]) end) =~
             "Coupling"

    assert capture_io(fn -> Map.run(["--boundaries", "--min", "3", "--top", "2"]) end) =~
             "Effect Boundaries"

    depth = capture_io(fn -> Map.run(["--depth", "--top", "1", "--format", "json"]) end)

    assert {:ok, %{"sections" => %{"depth" => [%{"depth" => depth_value} | _]}}} =
             Jason.decode(depth)

    assert is_integer(depth_value)

    data = capture_io(fn -> Map.run(["--data", "--top", "1", "--format", "json"]) end)

    assert {:ok, %{"sections" => %{"data" => %{"cross_function_edges" => edges}}}} =
             Jason.decode(data)

    assert is_list(edges)
  end

  defp decode_json(output) do
    json =
      output
      |> String.split("\n")
      |> Enum.drop_while(&(not String.starts_with?(&1, "{")))
      |> Enum.join("\n")

    assert {:ok, data} = Jason.decode(json)
    data
  end
end
