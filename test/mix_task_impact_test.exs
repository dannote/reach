defmodule Mix.Tasks.Reach.ImpactTest do
  use ExUnit.Case

  import ExUnit.CaptureIO

  alias Mix.Tasks.Reach.Impact

  test "runs without --graph flag" do
    output = capture_io(fn -> Impact.run(["Reach.Project.from_mix_project/0"]) end)
    assert output =~ "callers"
  end

  test "--graph flag" do
    output = capture_io(fn -> Impact.run(["Reach.Project.from_mix_project/0", "--graph"]) end)
    assert output =~ "Analyzing"
  end

  test "json format" do
    output = capture_io(fn -> Impact.run(["Reach.Project.from_mix_project/0", "--format", "json"]) end)
    json = strip_info_lines(output)
    assert {:ok, data} = Jason.decode(json)
    assert is_list(data["direct_callers"])
  end

  test "raises on missing target" do
    assert_raise Mix.Error, fn -> Impact.run([]) end
  end

  test "raises on unknown function" do
    assert_raise Mix.Error, ~r/not found/i, fn ->
      Impact.run(["NonExistent.Module.nope/0"])
    end
  end

  defp strip_info_lines(output) do
    output
    |> String.split("\n")
    |> Enum.drop_while(&(not String.starts_with?(&1, "{")))
    |> Enum.join("\n")
  end
end
