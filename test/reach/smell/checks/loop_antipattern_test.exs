defmodule Reach.Smell.Checks.LoopAntipatternTest do
  use ExUnit.Case, async: true

  defp findings(code) do
    path = Path.join(System.tmp_dir!(), "loop_test_#{:erlang.unique_integer([:positive])}.ex")
    File.write!(path, code)
    project = Reach.Project.from_sources([path])
    result = Reach.Smell.Checks.LoopAntipattern.run(project)
    File.rm(path)
    result
  end

  describe "++ inside loop" do
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

      assert Enum.any?(result, &(&1.kind == :suboptimal and &1.message =~ "++ inside loop"))
    end

    test "flags ++ in Enum.map" do
      result =
        findings("""
        defmodule A do
          def build(items, extra) do
            Enum.map(items, fn item -> extra ++ [item] end)
          end
        end
        """)

      assert Enum.any?(result, &(&1.message =~ "++ inside loop"))
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
  end

  describe "<> inside loop" do
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

      assert Enum.any?(result, &(&1.kind == :string_building and &1.message =~ "<> inside loop"))
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
  end
end
