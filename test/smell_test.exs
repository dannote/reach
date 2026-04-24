defmodule Reach.SmellTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Reach.Smell

  defp project_from_string(code) do
    path = Path.join(System.tmp_dir!(), "smell_test_#{:erlang.unique_integer([:positive])}.ex")
    File.write!(path, code)
    project = Reach.Project.from_sources([path])
    File.rm(path)
    project
  end

  defp run_smell_task(code) do
    project = project_from_string(code)

    ExUnit.CaptureIO.capture_io(fn ->
      send(self(), {:findings, Smell.analyze(project)})
    end)

    receive do
      {:findings, findings} -> findings
    after
      1000 -> []
    end
  end

  describe "Enum.map + List.first detection" do
    test "List.first inside Enum.map callback is a descendant" do
      graph =
        Reach.string_to_graph!("""
        def foo(rows) do
          Enum.map(rows, &List.first/1)
        end
        """)

      all = Reach.nodes(graph)

      map_call =
        Enum.find(
          all,
          &(&1.type == :call and &1.meta[:function] == :map and &1.meta[:module] == Enum)
        )

      first_call =
        Enum.find(
          all,
          &(&1.type == :call and &1.meta[:function] == :first and &1.meta[:module] == List)
        )

      assert map_call
      assert first_call

      descendant_ids = Reach.IR.all_nodes(map_call) |> Enum.map(& &1.id)
      assert first_call.id in descendant_ids
    end

    test "List.first after pipe is NOT a descendant of Enum.map" do
      graph =
        Reach.string_to_graph!("""
        def foo(rows) do
          rows |> Enum.map(&to_string/1) |> List.first()
        end
        """)

      all = Reach.nodes(graph)

      enum_calls =
        all
        |> Enum.filter(fn n ->
          n.type == :call and n.meta[:module] in [Enum, List] and n.source_span != nil
        end)
        |> Enum.sort_by(fn n -> n.source_span[:start_line] end)

      map_call = Enum.find(enum_calls, &(&1.meta[:function] == :map))
      first_call = Enum.find(enum_calls, &(&1.meta[:function] == :first))
      assert map_call && first_call

      descendant_ids = Reach.IR.all_nodes(map_call) |> Enum.map(& &1.id)
      refute first_call.id in descendant_ids
    end
  end

  describe "redundant computation exclusions" do
    test "field access calls are excluded from redundant detection" do
      graph =
        Reach.string_to_graph!("""
        def foo(state) do
          a = state.name
          b = state.name
          {a, b}
        end
        """)

      all = Reach.nodes(graph)

      field_calls =
        Enum.filter(all, fn n ->
          n.type == :call and n.meta[:kind] == :field_access
        end)

      assert length(field_calls) >= 2
    end
  end

  describe "false positive prevention" do
    test "pattern cons operator is not flagged as redundant" do
      findings =
        run_smell_task("""
        defmodule PatternTest do
          def foo(list) do
            case list do
              [a | rest] -> {a, rest}
              [b | tail] -> {b, tail}
            end
          end
        end
        """)

      pipe_findings =
        Enum.filter(findings, fn f ->
          f.kind == :redundant_computation and String.contains?(f.message, "|")
        end)

      assert pipe_findings == []
    end

    test "string interpolation to_string is not flagged" do
      findings =
        run_smell_task("""
        defmodule InterpolationTest do
          def greet(name) do
            header = "Hello \#{name}"
            IO.puts(header)
            footer = "Bye \#{name}"
            IO.puts(footer)
          end
        end
        """)

      to_string_findings =
        Enum.filter(findings, fn f ->
          f.kind == :redundant_computation and String.contains?(f.message, "to_string")
        end)

      assert to_string_findings == []
    end

    test "unrelated Enum.map and List.first are not flagged as eager" do
      findings =
        run_smell_task("""
        defmodule UnrelatedTest do
          def foo(items) do
            mapped = Enum.map(items, &to_string/1)
            first = List.first(other_list())
            {mapped, first}
          end

          defp other_list, do: [1, 2, 3]
        end
        """)

      eager = Enum.filter(findings, &(&1.kind == :eager_pattern))
      assert eager == []
    end

    test "actual duplicate pure calls are still detected" do
      findings =
        run_smell_task("""
        defmodule DuplicateTest do
          def foo(list) do
            a = Enum.count(list)
            IO.puts(a)
            b = Enum.count(list)
            b
          end
        end
        """)

      redundant = Enum.filter(findings, &(&1.kind == :redundant_computation))
      assert redundant != []
    end

    test "piped Enum.map into List.first IS detected" do
      findings =
        run_smell_task("""
        defmodule PipedEagerTest do
          def foo(items) do
            items |> Enum.map(&to_string/1) |> List.first()
          end
        end
        """)

      eager = Enum.filter(findings, &(&1.kind == :eager_pattern))
      assert eager != []
    end
  end
end
