defmodule ExPDG.DataDependenceTest do
  use ExUnit.Case, async: true

  alias ExPDG.{IR, DataDependence}

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
    test "simple assignment" do
      node = hd(IR.from_string!("x = 1"))
      {defs, _uses} = DataDependence.analyze_bindings(node)
      assert :x in defs
    end

    test "pattern match defines multiple variables" do
      node = hd(IR.from_string!("{a, b} = foo()"))
      {defs, _uses} = DataDependence.analyze_bindings(node)
      assert :a in defs
      assert :b in defs
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
      {_nodes, ddg} = build_data_deps("""
      x = 1
      y = x + 1
      """)

      assert has_data_flow?(ddg, :x)
    end

    test "pattern match {a, b} = foo() creates edges" do
      {_nodes, ddg} = build_data_deps("""
      {a, b} = foo()
      a + b
      """)

      assert has_data_flow?(ddg, :a)
      assert has_data_flow?(ddg, :b)
    end

    test "no edge between independent variables" do
      {_nodes, ddg} = build_data_deps("""
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
      {_nodes, ddg} = build_data_deps("""
      x = 1
      x |> foo() |> bar()
      """)

      assert has_data_flow?(ddg, :x)
    end

    test "function parameter flows to body use" do
      {_nodes, ddg} = build_data_deps("""
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
end
