defmodule Reach.IR.PropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Reach.IR

  property "all nodes have unique IDs" do
    check all(source <- simple_elixir_source()) do
      case IR.from_string(source) do
        {:ok, nodes} ->
          all = IR.all_nodes(nodes)
          ids = Enum.map(all, & &1.id)
          assert ids == Enum.uniq(ids)

        {:error, _} ->
          :ok
      end
    end
  end

  property "all nodes have a valid type" do
    valid_types = [
      :entry,
      :exit,
      :block,
      :literal,
      :var,
      :match,
      :call,
      :case,
      :clause,
      :guard,
      :fn,
      :try,
      :rescue,
      :catch_clause,
      :after,
      :receive,
      :comprehension,
      :generator,
      :filter,
      :binary_op,
      :unary_op,
      :tuple,
      :list,
      :cons,
      :map,
      :map_field,
      :struct,
      :pin,
      :access,
      :module_def,
      :function_def,
      :dispatch
    ]

    check all(source <- simple_elixir_source()) do
      case IR.from_string(source) do
        {:ok, nodes} ->
          all = IR.all_nodes(nodes)

          Enum.each(all, fn node ->
            assert node.type in valid_types, "invalid node type: #{inspect(node.type)}"
          end)

        {:error, _} ->
          :ok
      end
    end
  end

  # Generators for simple valid Elixir expressions
  defp simple_elixir_source do
    one_of([
      constant("42"),
      constant(":ok"),
      constant("x = 1"),
      constant("x + y"),
      constant("foo(1, 2)"),
      constant("Enum.map(list, &fun/1)"),
      constant("{1, 2, 3}"),
      constant("[1, 2, 3]"),
      constant("%{a: 1}"),
      constant("x |> foo() |> bar()"),
      constant("if x, do: 1, else: 2"),
      constant("case x do\n  :a -> 1\n  _ -> 2\nend"),
      constant("fn x -> x end")
    ])
  end
end
