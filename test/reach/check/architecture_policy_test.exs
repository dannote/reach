defmodule Reach.Check.ArchitecturePolicyTest do
  use ExUnit.Case

  import ExUnit.CaptureIO

  alias Mix.Tasks.Reach.Check

  test "reach.check validates an empty architecture policy" do
    with_reach_config(~S([layers: [cli: "Mix.Tasks.*", core: "Reach.*"]]))

    output = capture_io(fn -> Check.run(["--arch", "--format", "json"]) end)

    assert {:ok, data} = Jason.decode(output)
    assert data["status"] == "ok"
    assert data["violations"] == []
  end

  test "reach.check accepts grouped architecture policy" do
    with_reach_config(~S([
      layers: [cli: "Mix.Tasks.*", core: "Reach.*"],
      deps: [forbidden: []],
      calls: [forbidden: []],
      effects: [allowed: []],
      boundaries: [public: [], internal: [], internal_callers: []],
      tests: [hints: []],
      source: [forbidden_modules: [], forbidden_files: []]
    ]))

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

  test "reach.check reports grouped architecture config errors" do
    with_reach_config("[deps: [forbidden: :bad, unknown: []]]")

    assert_raise Mix.Error, ~r/Architecture policy failed/, fn ->
      capture_io(fn -> Check.run(["--arch", "--format", "json"]) end)
    end
  end

  test "reach.check validates forbidden call config shape" do
    with_reach_config(~S([forbidden_calls: :bad]))

    assert_raise Mix.Error, ~r/Architecture policy failed/, fn ->
      capture_io(fn -> Check.run(["--arch", "--format", "json"]) end)
    end
  end

  test "reach.check reports forbidden call violations" do
    with_reach_config(
      ~S([forbidden_calls: [{"Reach.CLI.Commands.Check", ["Reach.Config.read"]}]])
    )

    assert_raise Mix.Error, ~r/Architecture policy failed/, fn ->
      capture_io(fn -> Check.run(["--arch", "--format", "json"]) end)
    end
  end

  test "reach.check reports grouped forbidden call violations" do
    with_reach_config(
      ~S([calls: [forbidden: [{"Reach.CLI.Commands.Check", ["Reach.Config.read"]}]]])
    )

    assert_raise Mix.Error, ~r/Architecture policy failed/, fn ->
      capture_io(fn -> Check.run(["--arch", "--format", "json"]) end)
    end
  end

  test "reach.check reports forbidden source violations" do
    with_reach_config(~S([
      source: [
        forbidden_modules: ["Reach.CLI.Commands.Check"],
        forbidden_files: ["lib/reach/cli/commands/check.ex"]
      ]
    ]))

    assert_raise Mix.Error, ~r/Architecture policy failed/, fn ->
      capture_io(fn -> Check.run(["--arch", "--format", "json"]) end)
    end
  end

  test "reach.check allows forbidden call exceptions" do
    with_reach_config(
      ~S([forbidden_calls: [{"Reach.CLI.Commands.Check", ["File.exists?"], except: ["Reach.CLI.Commands.Check"]}]])
    )

    output = capture_io(fn -> Check.run(["--arch", "--format", "json"]) end)

    assert {:ok, data} = Jason.decode(output)
    assert data["status"] == "ok"
    assert data["violations"] == []
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
