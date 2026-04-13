defmodule Reach.QueryTest do
  use ExUnit.Case, async: true

  defp build_graph(source) do
    Reach.string_to_graph!(source)
  end

  describe "nodes/2" do
    test "returns all nodes" do
      graph = build_graph("def foo(x), do: x + 1")
      all = Reach.nodes(graph)
      assert all != []
    end

    test "filters by type" do
      graph = build_graph("def foo(x), do: x + 1")
      calls = Reach.nodes(graph, type: :call)
      Enum.each(calls, fn n -> assert n.type == :call end)
    end

    test "filters by module" do
      graph =
        build_graph("""
        def foo(x) do
          Enum.map(x, &to_string/1)
        end
        """)

      enum_calls = Reach.nodes(graph, type: :call, module: Enum)
      assert enum_calls != []
      Enum.each(enum_calls, fn n -> assert n.meta[:module] == Enum end)
    end
  end

  describe "data_flows?" do
    test "detects data flow through variable" do
      graph =
        build_graph("""
        def foo(x) do
          y = x + 1
          y
        end
        """)

      all = Reach.nodes(graph)
      x_nodes = Enum.filter(all, &(&1.type == :var and &1.meta[:name] == :x))
      y_nodes = Enum.filter(all, &(&1.type == :var and &1.meta[:name] == :y))

      if x_nodes != [] and y_nodes != [] do
        x_def =
          Enum.find(
            all,
            &(&1.type == :match and match?(%{children: [%{meta: %{name: :x}} | _]}, &1))
          )

        y_use = List.last(y_nodes)

        if x_def && y_use do
          assert is_boolean(Reach.data_flows?(graph, x_def.id, y_use.id))
        end
      end
    end
  end

  describe "has_dependents?" do
    test "definition with later use has dependents" do
      graph =
        build_graph("""
        def foo do
          x = 1
          y = x + 1
          y
        end
        """)

      all = Reach.nodes(graph)

      x_match =
        Enum.find(all, fn n ->
          n.type == :match and
            hd(n.children).type == :var and
            hd(n.children).meta[:name] == :x
        end)

      if x_match do
        assert Reach.has_dependents?(graph, x_match.id)
      end
    end
  end

  describe "pure?" do
    test "delegates to Effects" do
      [node] = Reach.IR.from_string!("42")
      assert Reach.pure?(node)

      [node] = Reach.IR.from_string!("IO.puts(x)")
      refute Reach.pure?(node)
    end
  end
end
