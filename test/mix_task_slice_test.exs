defmodule Mix.Tasks.Reach.SliceTest do
  use ExUnit.Case

  import ExUnit.CaptureIO

  alias Mix.Tasks.Reach.Slice

  @source_file "lib/reach/project.ex"

  test "runs without --graph flag" do
    output = capture_io(fn -> Slice.run(["#{@source_file}:1"]) end)
    assert output =~ "slice"
  end

  test "--graph flag" do
    output = capture_io(fn -> Slice.run(["#{@source_file}:1", "--graph"]) end)
    assert output =~ "Analyzing"
  end

  test "json format" do
    output = capture_io(fn -> Slice.run(["#{@source_file}:1", "--format", "json"]) end)
    json = strip_info_lines(output)
    assert {:ok, data} = Jason.decode(json)
    assert data["direction"] == "backward"
  end

  test "forward slice" do
    output = capture_io(fn -> Slice.run(["#{@source_file}:1", "--forward"]) end)
    assert output =~ "slice"
  end

  test "raises on missing target" do
    assert_raise Mix.Error, fn -> Slice.run([]) end
  end

  test "raises on invalid format" do
    assert_raise Mix.Error, fn -> Slice.run(["invalid"]) end
  end

  defp strip_info_lines(output) do
    output
    |> String.split("\n")
    |> Enum.drop_while(&(not String.starts_with?(&1, "{")))
    |> Enum.join("\n")
  end
end
