defmodule Reach.Smell.Checks.IdiomMismatchTest do
  use ExUnit.Case, async: true

  alias Reach.Smell.Checks.IdiomMismatch

  defp findings(code) do
    path = Path.join(System.tmp_dir!(), "idiom_test_#{:erlang.unique_integer([:positive])}.ex")
    File.write!(path, code)
    project = Reach.Project.from_sources([path])
    result = IdiomMismatch.run(project)
    File.rm(path)
    result
  end

  describe "guard equality where pattern match suffices" do
    test "flags == in guard comparing variable to literal" do
      result =
        findings("""
        defmodule A do
          def check(x) when x == :ok, do: true
          def check(_), do: false
        end
        """)

      assert Enum.any?(result, &(&1.message =~ "pattern matching"))
    end

    test "does not flag non-equality guard expressions" do
      result =
        findings("""
        defmodule A do
          def check(x) when x > 0, do: true
        end
        """)

      assert Enum.filter(result, &(&1.message =~ "pattern matching")) == []
    end

    test "does not flag equality between two variables" do
      result =
        findings("""
        defmodule A do
          def check(x, y) when x == y, do: true
        end
        """)

      assert Enum.filter(result, &(&1.message =~ "pattern matching")) == []
    end
  end

  describe "Map.update then Map.get/fetch on same variable" do
    test "flags Map.update followed by Map.get on same map" do
      result =
        findings("""
        defmodule A do
          def bump(state, key) do
            state = Map.update(state, key, 1, &(&1 + 1))
            val = Map.get(state, key)
            {state, val}
          end
        end
        """)

      assert Enum.any?(result, &(&1.message =~ "Map.update then Map.get"))
    end

    test "flags Map.update followed by Map.fetch on same map" do
      result =
        findings("""
        defmodule A do
          def bump(state, key) do
            state = Map.update(state, key, 1, &(&1 + 1))
            {:ok, val} = Map.fetch(state, key)
            {state, val}
          end
        end
        """)

      assert Enum.any?(result, &(&1.message =~ "Map.update then Map.get/fetch"))
    end

    test "does not flag Map.update and Map.get on different variables" do
      result =
        findings("""
        defmodule A do
          def bump(state, other, key) do
            state = Map.update(state, key, 1, &(&1 + 1))
            val = Map.get(other, key)
            {state, val}
          end
        end
        """)

      assert Enum.filter(result, &(&1.message =~ "traverses twice")) == []
    end
  end
end
