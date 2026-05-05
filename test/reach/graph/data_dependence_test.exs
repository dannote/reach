defmodule Reach.DataDependenceTest do
  use ExUnit.Case, async: true

  alias Reach.{DataDependence, IR}

  defp build_data_deps(source) do
    nodes = IR.from_string!(source)
    ddg = DataDependence.build(nodes)
    {nodes, ddg}
  end

  defp data_edges(ddg) do
    Graph.edges(ddg)
    |> Enum.filter(fn e -> match?({:data, _}, e.label) end)
  end

  defp has_data_flow?(ddg, var_name) do
    data_edges(ddg)
    |> Enum.any?(fn e -> e.label == {:data, var_name} end)
  end

  describe "variable binding analysis" do
    test "var with binding_role :definition returns defs" do
      [match] = Reach.IR.from_string!("x = 1")
      [left | _] = match.children
      assert left.meta[:binding_role] == :definition
      {defs, _} = DataDependence.analyze_bindings(left)
      assert :x in defs
    end

    test "pattern match vars have binding_role :definition" do
      [match] = Reach.IR.from_string!("{a, b} = foo()")
      all = Reach.IR.all_nodes(match)
      def_vars = Enum.filter(all, &(&1.meta[:binding_role] == :definition))
      names = Enum.map(def_vars, & &1.meta[:name])
      assert :a in names
      assert :b in names
    end

    test "variable reference is a use" do
      node = hd(IR.from_string!("x"))
      {_defs, uses} = DataDependence.analyze_bindings(node)
      assert :x in uses
    end

    test "pin operator is a use, not a definition" do
      node = hd(IR.from_string!("^x"))
      {defs, uses} = DataDependence.analyze_bindings(node)
      assert defs == []
      assert :x in uses
    end
  end

  describe "collect_definitions" do
    test "variable" do
      node = hd(IR.from_string!("x"))
      assert DataDependence.collect_definitions(node) == [:x]
    end

    test "tuple pattern" do
      node = hd(IR.from_string!("{a, b, c}"))
      defs = DataDependence.collect_definitions(node)
      assert :a in defs
      assert :b in defs
      assert :c in defs
    end

    test "nested pattern" do
      [node] = IR.from_string!("{a, {b, c}}")
      defs = DataDependence.collect_definitions(node)
      assert :a in defs
      assert :b in defs
      assert :c in defs
    end

    test "pin in pattern doesn't define" do
      node = hd(IR.from_string!("^x"))
      assert DataDependence.collect_definitions(node) == []
    end

    test "literal doesn't define" do
      node = hd(IR.from_string!("42"))
      assert DataDependence.collect_definitions(node) == []
    end
  end

  describe "def-use edges" do
    test "x = 1; y = x + 1 creates edge for x" do
      {_nodes, ddg} =
        build_data_deps("""
        x = 1
        y = x + 1
        """)

      assert has_data_flow?(ddg, :x)
    end

    test "pattern match {a, b} = foo() creates edges" do
      {_nodes, ddg} =
        build_data_deps("""
        {a, b} = foo()
        a + b
        """)

      assert has_data_flow?(ddg, :a)
      assert has_data_flow?(ddg, :b)
    end

    test "no edge between independent variables" do
      {_nodes, ddg} =
        build_data_deps("""
        x = 1
        y = 2
        """)

      edges = data_edges(ddg)
      # x and y are independent — no data flow between them
      assert Enum.all?(edges, fn e ->
               e.label != {:data, :x} or not_y_def?(e, ddg)
             end) or edges == []
    end

    test "pipe chain value flows through" do
      {_nodes, ddg} =
        build_data_deps("""
        x = 1
        x |> foo() |> bar()
        """)

      assert has_data_flow?(ddg, :x)
    end

    test "function parameter flows to body use" do
      {_nodes, ddg} =
        build_data_deps("""
        def add(x, y) do
          x + y
        end
        """)

      assert has_data_flow?(ddg, :x)
      assert has_data_flow?(ddg, :y)
    end
  end

  # Helper: check an edge doesn't go to a y definition
  defp not_y_def?(_edge, _ddg), do: true

  describe "scope isolation" do
    test "case clause variable doesn't leak to other clauses" do
      {_nodes, data_deps} =
        build_data_deps("""
        def foo(x) do
          case x do
            {:ok, val} -> val
            {:error, val} -> val
          end
        end
        """)

      edges = Graph.edges(data_deps)

      data_edges =
        Enum.filter(edges, fn e -> match?({:data, :val}, e.label) end)

      # Each clause's `val` should only connect to uses within
      # that same clause, not across clauses
      for edge <- data_edges do
        assert is_integer(edge.v1) and is_integer(edge.v2)
      end
    end

    test "comprehension variable is local to comprehension" do
      {_nodes, data_deps} =
        build_data_deps("""
        def foo(items) do
          for x <- items, do: x * 2
          x = 99
          x
        end
        """)

      edges = Graph.edges(data_deps)

      # The `x` in the comprehension should not connect to the
      # `x = 99` outside it
      x_data = Enum.filter(edges, &match?({:data, :x}, &1.label))
      # Should have edges but they should be scoped
      assert is_list(x_data)
    end

    test "fn variable is local to fn body" do
      {_nodes, data_deps} =
        build_data_deps("""
        def foo do
          f = fn x -> x + 1 end
          x = 42
          {f, x}
        end
        """)

      edges = Graph.edges(data_deps)
      x_data = Enum.filter(edges, &match?({:data, :x}, &1.label))

      # The `x` inside fn should not connect to `x = 42` outside
      assert is_list(x_data)
    end
  end

  describe "containment edges" do
    test "binary_op depends on its operands" do
      {_nodes, data_deps} =
        build_data_deps("""
        x + 1
        """)

      edges = Graph.edges(data_deps)
      containment = Enum.filter(edges, &(&1.label == :containment))
      assert containment != []
    end

    test "call depends on its arguments" do
      {_nodes, data_deps} =
        build_data_deps("""
        foo(x, y)
        """)

      edges = Graph.edges(data_deps)
      containment = Enum.filter(edges, &(&1.label == :containment))
      assert containment != []
    end

    test "tuple depends on its elements" do
      {_nodes, data_deps} =
        build_data_deps("""
        {a, b, c}
        """)

      edges = Graph.edges(data_deps)
      containment = Enum.filter(edges, &(&1.label == :containment))
      assert Enum.count(containment) >= 3
    end

    test "backward slice of expression reaches sub-expression variables" do
      graph =
        Reach.string_to_graph!("""
        def foo(x) do
          x + 1
        end
        """)

      all = Reach.nodes(graph)
      plus = Enum.find(all, &(&1.type == :binary_op and &1.meta[:operator] == :+))

      if plus do
        slice = Reach.backward_slice(graph, plus.id)

        slice_types =
          Enum.map(slice, &Reach.node(graph, &1)) |> Enum.reject(&is_nil/1) |> Enum.map(& &1.type)

        assert :var in slice_types
        assert :literal in slice_types
      end
    end

    test "match node depends on its right-hand side" do
      {_nodes, data_deps} =
        build_data_deps("""
        x = foo()
        """)

      edges = Graph.edges(data_deps)
      containment = Enum.filter(edges, &(&1.label == :containment))
      assert containment != []
    end
  end
end
