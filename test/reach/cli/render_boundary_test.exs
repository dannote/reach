defmodule Reach.CLI.RenderBoundaryTest do
  use ExUnit.Case

  test "canonical tasks do not call removed Reach mix tasks internally" do
    forbidden =
      ~r/TaskRunner\.run|Mix\.Tasks\.Reach\..*\.run|Mix\.Task\.run\("reach|Reach\.CLI\.TaskRunner|Reach\.CLI\.Analyses|Deprecation\.delegated/

    files = Path.wildcard("lib/**/*.ex")

    offenders =
      files
      |> Enum.flat_map(fn file ->
        file
        |> File.read!()
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.filter(fn {line, _line_number} -> line =~ forbidden end)
        |> Enum.map(fn {_line, line_number} -> "#{file}:#{line_number}" end)
      end)

    assert offenders == []
  end

  test "canonical command modules keep rendering in render layer" do
    forbidden = ~r/IO\.puts|Format\.render|Jason\.encode!/

    offenders =
      "lib/reach/cli/commands/**/*.ex"
      |> Path.wildcard()
      |> Enum.flat_map(fn file ->
        file
        |> File.read!()
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.filter(fn {line, _line_number} -> line =~ forbidden end)
        |> Enum.map(fn {_line, line_number} -> "#{file}:#{line_number}" end)
      end)

    assert offenders == []
  end
end
