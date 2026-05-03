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

  test "check and inspect domain findings use atom types and kinds" do
    forbidden = ~r/(type|kind):\s*"/

    offenders =
      [
        "lib/reach/check/**/*.ex",
        "lib/reach/inspect/**/*.ex",
        "lib/reach/trace/**/*.ex",
        "lib/reach/otp/**/*.ex",
        "lib/reach/map/**/*.ex"
      ]
      |> Enum.flat_map(&Path.wildcard/1)
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

  test "only Reach.Config loads .reach.exs files" do
    offenders =
      "lib/reach/**/*.ex"
      |> Path.wildcard()
      |> Enum.reject(&(&1 == "lib/reach/config.ex"))
      |> Enum.flat_map(fn file ->
        file
        |> File.read!()
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.filter(fn {line, _line_number} ->
          line =~ ~r/Code\.eval_file\("\.reach\.exs"\)|File\.exists\?\("\.reach\.exs"\)/
        end)
        |> Enum.map(fn {_line, line_number} -> "#{file}:#{line_number}" end)
      end)

    assert offenders == []
  end

  test "framework-specific policy stays out of generic smell and clone analysis" do
    forbidden =
      ~r/\b(Ecto|Repo|Oban|Phoenix|Ash|Jido|LiveView)\b|insert_all|update_all|delete_all|validate_required/

    offenders =
      ["lib/reach/smell/**/*.ex", "lib/reach/clone_analysis/**/*.ex"]
      |> Enum.flat_map(&Path.wildcard/1)
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
