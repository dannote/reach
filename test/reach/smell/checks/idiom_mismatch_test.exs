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

    test "reports clause location, not unknown" do
      result =
        findings("""
        defmodule A do
          def check(x) when x == :ok, do: true
        end
        """)

      finding = Enum.find(result, &(&1.message =~ "pattern matching"))
      assert finding
      refute finding.location == "unknown"
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

  describe "redundant negated guard" do
    test "flags when != guard follows == guard on same variables" do
      result =
        findings("""
        defmodule A do
          defp compare([h1 | t1], [h2 | t2]) when h1 == h2, do: compare(t1, t2)
          defp compare([h1 | _], [h2 | _]) when h1 != h2, do: h1
        end
        """)

      assert Enum.any?(result, &(&1.message =~ "redundant negated guard"))
    end

    test "does not flag unrelated guards" do
      result =
        findings("""
        defmodule A do
          def check(x) when x > 0, do: :pos
          def check(x) when x < 0, do: :neg
        end
        """)

      assert Enum.filter(result, &(&1.message =~ "redundant")) == []
    end
  end

  describe "destructure then reconstruct" do
    test "flags list destructured and reassembled in body" do
      result =
        findings("""
        defmodule A do
          def check(ip) do
            case String.split(ip, ".") do
              [p1, p2, p3, p4] -> Enum.all?([p1, p2, p3, p4], &valid?/1)
              _ -> false
            end
          end
        end
        """)

      assert Enum.any?(result, &(&1.message =~ "reassembled"))
    end

    test "does not flag when variables are used individually" do
      result =
        findings("""
        defmodule A do
          def check(ip) do
            case String.split(ip, ".") do
              [p1, p2, p3, p4] -> {p1, p2, p3, p4}
              _ -> :error
            end
          end
        end
        """)

      assert Enum.filter(result, &(&1.message =~ "reassembled")) == []
    end
  end
end
