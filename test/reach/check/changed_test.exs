defmodule Reach.Check.ChangedTest do
  use ExUnit.Case

  import ExUnit.CaptureIO

  alias Mix.Tasks.Reach.Check
  alias Reach.Check.Changed

  test "changed analysis reports cloned sibling functions" do
    in_tmp_git_repo(fn repo ->
      file = Path.join(repo, "lib/example.ex")
      File.mkdir_p!(Path.dirname(file))

      File.write!(file, """
      defmodule ExampleA do
        def normalize(value) do
          value = String.trim(value)
          {:ok, value}
        end
      end

      defmodule ExampleB do
        def normalize(value) do
          value = String.trim(value)
          {:ok, value}
        end
      end
      """)

      git!(repo, ["add", "."])
      git!(repo, ["commit", "-m", "initial"])

      File.write!(file, """
      defmodule ExampleA do
        def normalize(value) do
          value = String.trim(value)
          {:ok, value}
        end
      end

      defmodule ExampleB do
        def normalize(value) do
          value = String.trim(value)
          {:ok, String.downcase(value)}
        end
      end
      """)

      git!(repo, ["add", "."])
      git!(repo, ["commit", "-m", "change clone"])

      project = Reach.Project.from_sources([file])

      result =
        File.cd!(repo, fn ->
          Changed.run(project, [clone_analysis: [min_mass: 3, min_similarity: 0.5]],
            base: "HEAD~1"
          )
        end)

      assert [%{id: "normalize/1", clone_siblings: [_ | _]}] = result.changed_functions
    end)
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

  defp in_tmp_git_repo(fun) do
    repo =
      Path.join(System.tmp_dir!(), "reach_changed_test_#{:erlang.unique_integer([:positive])}")

    File.mkdir_p!(repo)

    try do
      git!(repo, ["init"])
      git!(repo, ["config", "user.email", "reach@example.invalid"])
      git!(repo, ["config", "user.name", "Reach Test"])
      fun.(repo)
    after
      File.rm_rf!(repo)
    end
  end

  defp git!(repo, args) do
    case System.cmd("git", args, cd: repo, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> flunk("git #{Enum.join(args, " ")} failed with #{status}: #{output}")
    end
  end
end
