defmodule Reach.Smell.Checks.LoopAntipatternTest do
  use ExUnit.Case, async: true

  alias Reach.Smell.Checks.LoopAntipattern

  defp findings(code) do
    path = Path.join(System.tmp_dir!(), "loop_test_#{:erlang.unique_integer([:positive])}.ex")
    File.write!(path, code)
    project = Reach.Project.from_sources([path])
    result = LoopAntipattern.run(project)
    File.rm(path)
    result
  end

  describe "++ inside reduce" do
    test "flags ++ in Enum.reduce" do
      result =
        findings("""
        defmodule A do
          def build(items) do
            Enum.reduce(items, [], fn item, acc ->
              acc ++ [item]
            end)
          end
        end
        """)

      assert Enum.any?(result, &(&1.kind == :suboptimal and &1.message =~ "++ inside reduce"))
    end

    test "does not flag ++ in Enum.map (no accumulator)" do
      result =
        findings("""
        defmodule A do
          def build(items, extra) do
            Enum.map(items, fn item -> extra ++ [item] end)
          end
        end
        """)

      assert Enum.filter(result, &(&1.message =~ "++")) == []
    end

    test "does not flag ++ outside a loop" do
      result =
        findings("""
        defmodule A do
          def build(a, b), do: a ++ b
        end
        """)

      assert Enum.filter(result, &(&1.message =~ "++")) == []
    end

    test "flags ++ when recursive call result feeds into operand" do
      result =
        findings("""
        defmodule A do
          def flatten([h | t]) when is_list(h), do: flatten(h) ++ flatten(t)
          def flatten([h | t]), do: [h | flatten(t)]
          def flatten([]), do: []
        end
        """)

      assert Enum.any?(result, &(&1.message =~ "++"))
    end

    test "does not flag ++ in recursive function when operands are local" do
      result =
        findings("""
        defmodule A do
          def walk(tree) do
            exits = body(tree) ++ rescue(tree)
            walk(tree.child)
            exits
          end
          defp body(_), do: [1]
          defp rescue(_), do: [2]
        end
        """)

      assert Enum.filter(result, &(&1.message =~ "++")) == []
    end

    test "does not flag ++ in Enum.flat_map (no accumulator)" do
      result =
        findings("""
        defmodule A do
          def build(items) do
            Enum.flat_map(items, fn item -> item ++ [1] end)
          end
        end
        """)

      assert Enum.filter(result, &(&1.message =~ "++")) == []
    end
  end

  describe "<> inside reduce" do
    test "flags <> in Enum.reduce" do
      result =
        findings("""
        defmodule A do
          def build(items) do
            Enum.reduce(items, "", fn item, acc ->
              acc <> item
            end)
          end
        end
        """)

      assert Enum.any?(
               result,
               &(&1.kind == :string_building and &1.message =~ "<> inside reduce")
             )
    end

    test "does not flag <> outside a loop" do
      result =
        findings("""
        defmodule A do
          def greet(name), do: "hello " <> name
        end
        """)

      assert Enum.filter(result, &(&1.message =~ "<>")) == []
    end
  end

  describe "manual min/max/sum reduce" do
    test "flags manual min reduce" do
      result =
        findings("""
        defmodule A do
          def smallest(items) do
            Enum.reduce(items, fn item, acc -> min(item, acc) end)
          end
        end
        """)

      assert Enum.any?(result, &(&1.message =~ "min"))
    end

    test "flags manual max reduce" do
      result =
        findings("""
        defmodule A do
          def largest(items) do
            Enum.reduce(items, fn item, acc -> max(item, acc) end)
          end
        end
        """)

      assert Enum.any?(result, &(&1.message =~ "max"))
    end

    test "flags manual sum reduce" do
      result =
        findings("""
        defmodule A do
          def total(items) do
            Enum.reduce(items, 0, fn item, acc -> acc + item end)
          end
        end
        """)

      assert Enum.any?(result, &(&1.message =~ "sum"))
    end

    test "does not flag complex accumulator with +" do
      result =
        findings("""
        defmodule A do
          def count_present(items) do
            Enum.reduce(items, {0, 0}, fn item, {present, count} ->
              if item, do: {present + 1, count + 1}, else: {present, count + 1}
            end)
          end
        end
        """)

      assert Enum.filter(result, &(&1.message =~ "sum")) == []
    end
  end

  describe "manual frequency counting" do
    test "flags Map.update inside reduce with empty map accumulator" do
      result =
        findings("""
        defmodule A do
          def freq(items) do
            Enum.reduce(items, %{}, fn item, acc ->
              Map.update(acc, item, 1, &(&1 + 1))
            end)
          end
        end
        """)

      assert Enum.any?(result, &(&1.message =~ "frequencies"))
    end

    test "does not flag complex reduce with Map.update" do
      result =
        findings("""
        defmodule A do
          def index(files) do
            Enum.reduce(files, %{}, fn file, acc ->
              case File.read(file) do
                {:ok, content} ->
                  content
                  |> extract_keys()
                  |> Enum.reduce(acc, fn key, inner_acc ->
                    Map.update(inner_acc, key, [file], &[file | &1])
                  end)
                _ -> acc
              end
            end)
          end
          defp extract_keys(c), do: [c]
        end
        """)

      assert Enum.filter(result, &(&1.message =~ "frequencies")) == []
    end
  end
end
