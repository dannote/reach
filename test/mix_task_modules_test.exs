defmodule Mix.Tasks.Reach.ModulesTest do
  use ExUnit.Case

  import ExUnit.CaptureIO

  alias Mix.Tasks.Reach.Modules

  test "runs without --graph flag" do
    output = capture_io(fn -> Modules.run([]) end)
    assert output =~ "Modules"
  end

  test "--graph flag" do
    output = capture_io(fn -> Modules.run(["--graph"]) end)
    assert output =~ "Analyzing"
  end

  test "json format" do
    output = capture_io(fn -> Modules.run(["--format", "json"]) end)
    json = strip_info_lines(output)
    assert {:ok, data} = Jason.decode(json)
    assert is_list(data["modules"])
  end

  test "oneline format" do
    output = capture_io(fn -> Modules.run(["--format", "oneline"]) end)
    assert output =~ "public"
    assert output =~ "complexity="
  end

  test "sort by complexity" do
    output = capture_io(fn -> Modules.run(["--sort", "complexity"]) end)
    assert output =~ "Modules"
  end

  defp strip_info_lines(output) do
    output
    |> String.split("\n")
    |> Enum.drop_while(&(not String.starts_with?(&1, "{")))
    |> Enum.join("\n")
  end
end
