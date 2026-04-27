defmodule Mix.Tasks.Reach.ModulesTest do
  use ExUnit.Case

  import ExUnit.CaptureIO

  alias Mix.Tasks.Reach.Modules

  test "delegates text output to reach.map --modules" do
    output = capture_io(fn -> Modules.run(["--top", "2"]) end)
    assert output =~ "Reach Map"
    assert output =~ "Modules"
  end

  test "json format uses canonical reach.map envelope" do
    output = capture_io(fn -> Modules.run(["--format", "json", "--top", "2"]) end)
    json = strip_info_lines(output)

    assert {:ok, data} = Jason.decode(json)
    assert data["command"] == "reach.map"
    assert is_list(data["sections"]["modules"])
  end

  test "oneline format" do
    output = capture_io(fn -> Modules.run(["--format", "oneline", "--top", "2"]) end)
    assert output =~ "module"
    assert output =~ "complexity="
  end

  test "sort by complexity" do
    output = capture_io(fn -> Modules.run(["--sort", "complexity", "--top", "2"]) end)
    assert output =~ "Modules"
  end

  defp strip_info_lines(output) do
    output
    |> String.split("\n")
    |> Enum.drop_while(&(not String.starts_with?(&1, "{")))
    |> Enum.join("\n")
  end
end
