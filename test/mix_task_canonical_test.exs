defmodule Mix.Tasks.Reach.CanonicalTest do
  use ExUnit.Case

  import ExUnit.CaptureIO

  alias Mix.Tasks.Reach.Check
  alias Mix.Tasks.Reach.Inspect
  alias Mix.Tasks.Reach.Map
  alias Mix.Tasks.Reach.Modules
  alias Mix.Tasks.Reach.Trace

  test "removed compatibility tasks raise with migration guidance" do
    assert_raise Mix.Error,
                 ~r/mix reach.modules has been removed; use mix reach.map --modules/,
                 fn ->
                   Modules.run(["--format", "oneline", "--top", "1"])
                 end
  end

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

  test "reach.map emits a consolidated json envelope" do
    output = capture_io(fn -> Map.run(["--format", "json", "--top", "2"]) end)

    assert String.starts_with?(output, "{")
    assert {:ok, data} = Jason.decode(output)
    assert data["command"] == "reach.map"
    assert is_map(data["summary"])
    assert is_map(data["sections"])
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

  test "reach.inspect preserves call graph rendering option" do
    output = capture_io(fn -> Inspect.run(["Reach.to_dot/1", "--call-graph"]) end)

    assert output =~ "to_dot/1"
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

  test "reach.inspect explains module dependency paths" do
    output = capture_io(fn -> Inspect.run(["Reach.CLI.Project", "--why", "Reach.Project"]) end)

    assert output =~ "module_dependency_path"
    assert output =~ "Reach.CLI.Project"
    assert output =~ "Reach.Project"
  end

  test "reach.trace runs variable tracing directly" do
    output =
      capture_io(fn ->
        Trace.run(["--variable", "graph", "--in", "Reach.to_dot/1", "--format", "oneline"])
      end)

    assert output =~ "graph"
  end

  test "canonical tasks do not call removed Reach mix tasks internally" do
    forbidden =
      ~r/TaskRunner\.run|Mix\.Tasks\.Reach\..*\.run|Mix\.Task\.run\("reach|Reach\.CLI\.TaskRunner|Deprecation\.delegated/

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

  test "reach.check validates an empty architecture policy" do
    with_reach_config(~S([layers: [cli: "Mix.Tasks.*", core: "Reach.*"]]))

    output = capture_io(fn -> Check.run(["--arch", "--format", "json"]) end)

    assert {:ok, data} = Jason.decode(output)
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

  defp decode_json(output) do
    json =
      output
      |> String.split("\n")
      |> Enum.drop_while(&(not String.starts_with?(&1, "{")))
      |> Enum.join("\n")

    assert {:ok, data} = Jason.decode(json)
    data
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
