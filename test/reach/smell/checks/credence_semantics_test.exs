defmodule Reach.Smell.Checks.CredenceSemanticsTest do
  use ExUnit.Case, async: true

  alias Reach.Check.Smells

  defp findings(code) do
    path =
      Path.join(System.tmp_dir!(), "credence_semantics_#{:erlang.unique_integer([:positive])}.ex")

    File.write!(path, code)

    path
    |> then(&Reach.Project.from_sources([&1]))
    |> Smells.run([])
  end

  defp messages(code) do
    code
    |> findings()
    |> Enum.map(& &1.message)
  end

  test "detects Map.has_key?/2 followed by reading the same key" do
    assert messages("""
           defmodule Sample do
             def lookup(map, key) do
               if Map.has_key?(map, key) do
                 Map.get(map, key)
               end
             end
           end
           """)
           |> Enum.any?(&String.contains?(&1, "two lookups"))
  end

  test "does not flag Map.has_key?/2 when reading a different key" do
    refute messages("""
           defmodule Sample do
             def lookup(map, key, other) do
               if Map.has_key?(map, key) do
                 Map.get(map, other)
               end
             end
           end
           """)
           |> Enum.any?(&String.contains?(&1, "two lookups"))
  end

  test "detects sentinel Map.get/3 followed by sentinel comparison" do
    assert messages("""
           defmodule Sample do
             def lookup(map, key) do
               value = Map.get(map, key, -1)

               if value == -1 do
                 :missing
               else
                 value
               end
             end
           end
           """)
           |> Enum.any?(&String.contains?(&1, "sentinel default"))
  end

  test "does not flag Map.get/3 sentinel defaults unless the sentinel is compared immediately" do
    refute messages("""
           defmodule Sample do
             def lookup(map, key) do
               value = Map.get(map, key, -1)
               {:ok, value}
             end
           end
           """)
           |> Enum.any?(&String.contains?(&1, "sentinel default"))
  end

  test "detects length-based indexing" do
    assert messages("""
           defmodule Sample do
             def last(list) do
               n = length(list)
               Enum.at(list, n - 1)
             end
           end
           """)
           |> Enum.any?(&String.contains?(&1, "length - n"))
  end

  test "detects missing require Logger" do
    assert messages("""
           defmodule Sample do
             def log do
               Logger.info("hello")
             end
           end
           """)
           |> Enum.any?(&String.contains?(&1, "require Logger"))
  end

  test "does not flag Logger calls when Logger is required" do
    refute messages("""
           defmodule Sample do
             require Logger

             def log do
               Logger.info("hello")
             end
           end
           """)
           |> Enum.any?(&String.contains?(&1, "require Logger"))
  end

  test "detects Credence collection idioms" do
    msgs =
      messages("""
      defmodule Sample do
        def sort_reverse(xs), do: xs |> Enum.sort() |> Enum.reverse()
        def sort_at(xs), do: xs |> Enum.sort() |> Enum.at(-1)
        def prefix_count(xs), do: xs |> Enum.take_while(& &1) |> length()
      end
      """)

    assert Enum.any?(msgs, &String.contains?(&1, "sorts ascending then reverses"))
    assert Enum.any?(msgs, &String.contains?(&1, "sorts the whole collection"))
    assert Enum.any?(msgs, &String.contains?(&1, "take_while"))
  end

  test "detects integer Keyword keys without flagging integer defaults" do
    msgs =
      messages("""
      defmodule Sample do
        def bad(opts), do: Keyword.get(opts, 1, :default)
        def ok(opts, key), do: opts |> Keyword.get(key, 0)
      end
      """)

    assert Enum.count(msgs, &String.contains?(&1, "Keyword keys must be atoms")) == 1
  end
end
