defmodule ExPDG.ControlDependenceTest do
  use ExUnit.Case, async: true

  alias ExPDG.{IR, ControlFlow, ControlDependence}

  defp build_control_deps(source) do
    [func_def] = IR.from_string!(source)
    control_flow = ControlFlow.build(func_def)
    control_deps = ControlDependence.build(control_flow)
    {func_def, control_flow, control_deps}
  end


  defp has_control_edge?(control_deps, from, to) do
    Graph.edges(control_deps)
    |> Enum.any?(fn e -> e.v1 == from and e.v2 == to end)
  end

  describe "basic control dependence" do
    test "if/else: both branches control-dependent on condition" do
      {_func, _control_flow, control_deps} = build_control_deps("""
      def foo(x) do
        if x > 0 do
          :positive
        else
          :negative
        end
      end
      """)

      # The CDG should have control dependence edges
      edges = Graph.edges(control_deps)
      control_edges = Enum.filter(edges, fn e ->
        match?({:control, _}, e.label)
      end)

      assert length(control_edges) > 0
    end

    test "contains all control flow vertices" do
      {_func, control_flow, control_deps} = build_control_deps("""
      def foo(x) do
        if x > 0 do
          :positive
        else
          :negative
        end
      end
      """)

      cfg_vertices = Graph.vertices(control_flow) |> MapSet.new()
      cdg_vertices = Graph.vertices(control_deps) |> MapSet.new()

      assert MapSet.subset?(cfg_vertices, cdg_vertices)
    end

    test "straight-line code: no control dependence edges" do
      {_func, _control_flow, control_deps} = build_control_deps("""
      def foo(x) do
        a = x + 1
        b = a + 2
        b
      end
      """)

      # In straight-line code, every node post-dominates its predecessor,
      # so there are no control dependence edges
      control_edges = Graph.edges(control_deps) |> Enum.filter(fn e ->
        match?({:control, _}, e.label)
      end)

      assert control_edges == []
    end
  end

  describe "control dependence from hand-built control flow" do
    test "diamond: branches control-dependent on condition" do
      # Build a manual diamond CFG:
      #  entry -> cond -> true_branch -> join -> exit
      #  entry -> cond -> false_branch -> join -> exit
      control_flow =
        Graph.new()
        |> Graph.add_edge(:entry, :cond, label: :sequential)
        |> Graph.add_edge(:cond, :true_branch, label: :true_branch)
        |> Graph.add_edge(:cond, :false_branch, label: :false_branch)
        |> Graph.add_edge(:true_branch, :join, label: :sequential)
        |> Graph.add_edge(:false_branch, :join, label: :sequential)
        |> Graph.add_edge(:join, :exit, label: :return)

      control_deps = ControlDependence.build(control_flow)

      # true_branch and false_branch should be control-dependent on cond
      assert has_control_edge?(control_deps, :cond, :true_branch)
      assert has_control_edge?(control_deps, :cond, :false_branch)

      # join should NOT be control-dependent on cond (post-dominated by exit)
      refute has_control_edge?(control_deps, :cond, :join)
    end

    test "nested branches: inner depends on outer" do
      # entry -> A -> B -> D -> exit
      # entry -> A -> C -> D -> exit
      # A -> B: true
      # A -> C: false
      # B has inner branch: B -> E, B -> F, both -> D
      control_flow =
        Graph.new()
        |> Graph.add_edge(:entry, :a, label: :sequential)
        |> Graph.add_edge(:a, :b, label: :true_branch)
        |> Graph.add_edge(:a, :c, label: :false_branch)
        |> Graph.add_edge(:b, :e, label: :true_branch)
        |> Graph.add_edge(:b, :f, label: :false_branch)
        |> Graph.add_edge(:e, :d, label: :sequential)
        |> Graph.add_edge(:f, :d, label: :sequential)
        |> Graph.add_edge(:c, :d, label: :sequential)
        |> Graph.add_edge(:d, :exit, label: :return)

      control_deps = ControlDependence.build(control_flow)

      # B and C control-dependent on A
      assert has_control_edge?(control_deps, :a, :b)
      assert has_control_edge?(control_deps, :a, :c)

      # E and F control-dependent on B
      assert has_control_edge?(control_deps, :b, :e)
      assert has_control_edge?(control_deps, :b, :f)
    end

    test "unconditional code: dependent only on entry" do
      # entry -> a -> b -> c -> exit (all sequential)
      control_flow =
        Graph.new()
        |> Graph.add_edge(:entry, :a, label: :sequential)
        |> Graph.add_edge(:a, :b, label: :sequential)
        |> Graph.add_edge(:b, :c, label: :sequential)
        |> Graph.add_edge(:c, :exit, label: :return)

      control_deps = ControlDependence.build(control_flow)

      # No control dependence edges expected for linear code
      # (each node is post-dominated by its successor)
      control_edges = Graph.edges(control_deps) |> Enum.filter(fn e ->
        match?({:control, _}, e.label)
      end)

      # In linear code, the only control dependence should be on :entry
      # (all nodes always execute if entry is reached)
      non_entry_sources =
        control_edges
        |> Enum.map(& &1.v1)
        |> Enum.reject(&(&1 == :entry))
        |> Enum.uniq()

      assert non_entry_sources == []
    end
  end
end
