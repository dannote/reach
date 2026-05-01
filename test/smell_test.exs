defmodule Reach.SmellTest do
  use ExUnit.Case, async: true

  alias Reach.CLI.Analyses.Smell

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

  describe "Credence-inspired collection pipeline smells" do
    test "flags sort then reverse" do
      findings =
        run_smell_task("""
        defmodule SortReverse do
          def f(items), do: items |> Enum.sort() |> Enum.reverse()
        end
        """)

      assert Enum.any?(
               findings,
               &(&1.kind == :eager_pattern and &1.message =~ "sort(enumerable, :desc)")
             )
    end

    test "flags sort then at" do
      findings =
        run_smell_task("""
        defmodule SortAt do
          def f(items), do: items |> Enum.sort() |> Enum.at(0)
        end
        """)

      assert Enum.any?(
               findings,
               &(&1.kind == :eager_pattern and &1.message =~ "full sort for one element")
             )
    end

    test "flags non-negative drop then take" do
      findings =
        run_smell_task("""
        defmodule DropTake do
          def f(items), do: items |> Enum.drop(5) |> Enum.take(10)
        end
        """)

      assert Enum.any?(findings, &(&1.kind == :eager_pattern and &1.message =~ "Enum.slice/3"))
    end

    test "does not flag negative drop then take" do
      findings =
        run_smell_task("""
        defmodule DropTakeTail do
          def f(items), do: items |> Enum.drop(-1) |> Enum.take(2)
        end
        """)

      refute Enum.any?(findings, &(&1.kind == :eager_pattern and &1.message =~ "Enum.slice/3"))
    end

    test "flags take_while then length" do
      findings =
        run_smell_task("""
        defmodule TakeWhileLength do
          def f(items), do: items |> Enum.take_while(& &1.ok?) |> length()
        end
        """)

      assert Enum.any?(
               findings,
               &(&1.kind == :eager_pattern and &1.message =~ "intermediate list")
             )
    end

    test "flags reverse append" do
      findings =
        run_smell_task("""
        defmodule ReverseAppend do
          def f(acc, tail), do: Enum.reverse(acc) ++ tail
        end
        """)

      assert Enum.any?(
               findings,
               &(&1.kind == :suboptimal and &1.message =~ "Enum.reverse(list, tail)")
             )
    end

    test "flags map then join as map_join candidate" do
      findings =
        run_smell_task("""
        defmodule MapJoin do
          def f(items), do: items |> Enum.map(& &1.name) |> Enum.join(",")
        end
        """)

      assert Enum.any?(findings, &(&1.kind == :eager_pattern and &1.message =~ "Enum.map_join/3"))
    end
  end

  describe "dual atom/string key access detection" do
    test "flags same map variable accessed with string and atom keys" do
      findings =
        run_smell_task("""
        defmodule LooseContract do
          def failure_manifest(metadata) do
            metadata["analyzer"] || metadata[:analyzer]
          end
        end
        """)

      assert [%{kind: :dual_key_access} = finding] =
               Enum.filter(findings, &(&1.kind == :dual_key_access))

      assert finding.message =~ "metadata"
      assert finding.message =~ "analyzer"
      assert finding.message =~ "normalize the map once or use a struct/contract"
    end

    test "flags Map.get with mixed key types" do
      findings =
        run_smell_task("""
        defmodule LooseContract do
          def fetch(metadata) do
            Map.get(metadata, "command") || Map.get(metadata, :command)
          end
        end
        """)

      assert [%{kind: :dual_key_access}] = Enum.filter(findings, &(&1.kind == :dual_key_access))
    end

    test "does not flag different map variables" do
      findings =
        run_smell_task("""
        defmodule SeparateContracts do
          def fetch(params, metadata) do
            params["id"] || metadata[:id]
          end
        end
        """)

      assert Enum.filter(findings, &(&1.kind == :dual_key_access)) == []
    end
  end

  describe "fixed-shape map detection" do
    test "flags repeated atom-key map shapes" do
      findings =
        run_smell_task("""
        defmodule RepeatedShapes do
          def a, do: %{id: 1, kind: :a, target: "a"}
          def b, do: %{id: 2, kind: :b, target: "b"}
          def c, do: %{id: 3, kind: :c, target: "c"}
        end
        """)

      assert [%{kind: :fixed_shape_map} = finding] =
               Enum.filter(findings, &(&1.kind == :fixed_shape_map))

      assert finding.keys == ["id", "kind", "target"]
      assert finding.occurrences == 3
      assert finding.message =~ "consider a struct or explicit contract"
    end

    test "does not flag isolated map literals" do
      findings =
        run_smell_task("""
        defmodule OneShape do
          def a, do: %{id: 1, kind: :a, target: "a"}
        end
        """)

      assert Enum.filter(findings, &(&1.kind == :fixed_shape_map)) == []
    end
  end

  describe "string building (iolist) detection" do
    test "Enum.map with interpolation piped to Enum.join" do
      findings =
        run_smell_task("""
        defmodule MapJoinInterp do
          def render(items) do
            items
            |> Enum.map(fn item -> "<li>\#{item.name}</li>" end)
            |> Enum.join()
          end
        end
        """)

      string = Enum.filter(findings, &(&1.kind == :string_building))
      assert length(string) == 1
      assert hd(string).message =~ "Enum.map"
      assert hd(string).message =~ "Enum.join"
    end

    test "Enum.map_join with string interpolation" do
      findings =
        run_smell_task("""
        defmodule MapJoinDirect do
          def render(rows) do
            Enum.map_join(rows, ",", fn r -> "\#{r.id}:\#{r.name}" end)
          end
        end
        """)

      string = Enum.filter(findings, &(&1.kind == :string_building))
      assert length(string) == 1
      assert hd(string).message =~ "map_join"
    end

    test "string concat around Enum.join" do
      findings =
        run_smell_task("""
        defmodule ConcatJoin do
          def render(items) do
            "<ul>" <> Enum.join(items, ",") <> "</ul>"
          end
        end
        """)

      string = Enum.filter(findings, &(&1.kind == :string_building))
      assert length(string) == 1
      assert hd(string).message =~ "wrap in a list"
    end

    test "Enum.reduce building string with <>" do
      findings =
        run_smell_task("""
        defmodule ReduceConcat do
          def build(rows) do
            Enum.reduce(rows, "", fn row, acc ->
              acc <> row.name <> ","
            end)
          end
        end
        """)

      string = Enum.filter(findings, &(&1.kind == :string_building))
      assert length(string) == 1
      assert hd(string).message =~ "O(n²)"
    end

    test "iolist in Enum.map is NOT flagged" do
      findings =
        run_smell_task("""
        defmodule GoodIolist do
          def render(items) do
            Enum.map(items, fn item -> ["<li>", item.name, "</li>"] end)
          end
        end
        """)

      string = Enum.filter(findings, &(&1.kind == :string_building))
      assert string == []
    end

    test "Enum.join without interpolation in callback is NOT flagged" do
      findings =
        run_smell_task("""
        defmodule PlainJoin do
          def render(items) do
            items |> Enum.map(& &1.name) |> Enum.join(", ")
          end
        end
        """)

      string = Enum.filter(findings, &(&1.kind == :string_building))
      assert string == []
    end

    test "simple string interpolation outside loop is NOT flagged" do
      findings =
        run_smell_task("""
        defmodule SimpleInterp do
          def greet(name), do: "hello \#{name}"
        end
        """)

      string = Enum.filter(findings, &(&1.kind == :string_building))
      assert string == []
    end
  end
end
