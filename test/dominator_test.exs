defmodule Reach.DominatorTest do
  use ExUnit.Case, async: true

  alias Reach.Dominator

  # Helper to build a simple graph
  defp graph(edges) do
    Enum.reduce(edges, Graph.new(), fn {a, b}, g ->
      Graph.add_edge(g, a, b)
    end)
  end

  describe "immediate dominators" do
    test "linear graph: each node dominated by predecessor" do
      #  A -> B -> C -> D
      g = graph([{:a, :b}, {:b, :c}, {:c, :d}])
      idom = Dominator.idom(g, :a)

      assert idom[:a] == :a
      assert idom[:b] == :a
      assert idom[:c] == :b
      assert idom[:d] == :c
    end

    test "diamond: join node dominated by root" do
      #     A
      #    / \
      #   B   C
      #    \ /
      #     D
      g = graph([{:a, :b}, {:a, :c}, {:b, :d}, {:c, :d}])
      idom = Dominator.idom(g, :a)

      assert idom[:a] == :a
      assert idom[:b] == :a
      assert idom[:c] == :a
      assert idom[:d] == :a
    end

    test "sequential with branch" do
      #  A -> B -> C
      #  A -> D -> C
      g = graph([{:a, :b}, {:b, :c}, {:a, :d}, {:d, :c}])
      idom = Dominator.idom(g, :a)

      assert idom[:a] == :a
      assert idom[:b] == :a
      assert idom[:d] == :a
      assert idom[:c] == :a
    end

    test "nested diamond" do
      #      A
      #     / \
      #    B   C
      #    |   |
      #    D   E
      #     \ /
      #      F
      g = graph([{:a, :b}, {:a, :c}, {:b, :d}, {:c, :e}, {:d, :f}, {:e, :f}])
      idom = Dominator.idom(g, :a)

      assert idom[:a] == :a
      assert idom[:b] == :a
      assert idom[:c] == :a
      assert idom[:d] == :b
      assert idom[:e] == :c
      assert idom[:f] == :a
    end
  end

  describe "post-dominators" do
    test "linear: each node post-dominated by successor" do
      g = graph([{:a, :b}, {:b, :c}, {:c, :d}])
      ipdom = Dominator.ipdom(g, :d)

      assert ipdom[:d] == :d
      assert ipdom[:c] == :d
      assert ipdom[:b] == :c
      assert ipdom[:a] == :b
    end

    test "diamond: join node post-dominates both branches" do
      g = graph([{:a, :b}, {:a, :c}, {:b, :d}, {:c, :d}])
      ipdom = Dominator.ipdom(g, :d)

      assert ipdom[:d] == :d
      assert ipdom[:b] == :d
      assert ipdom[:c] == :d
      assert ipdom[:a] == :d
    end

    test "multiple exits: synthetic exit post-dominates all" do
      #  entry -> A -> exit
      #  entry -> B -> exit
      g = graph([{:entry, :a}, {:entry, :b}, {:a, :exit}, {:b, :exit}])
      ipdom = Dominator.ipdom(g, :exit)

      assert ipdom[:exit] == :exit
      assert ipdom[:a] == :exit
      assert ipdom[:b] == :exit
      assert ipdom[:entry] == :exit
    end
  end

  describe "dominator tree" do
    test "builds tree from idom map" do
      g = graph([{:a, :b}, {:a, :c}, {:b, :d}, {:c, :d}])
      idom = Dominator.idom(g, :a)
      dom_tree = Dominator.tree(idom)

      # A dominates B, C, D
      assert Graph.edge(dom_tree, :a, :b, :dominates) != nil
      assert Graph.edge(dom_tree, :a, :c, :dominates) != nil
      assert Graph.edge(dom_tree, :a, :d, :dominates) != nil
      # B and C do not dominate anything
      assert Graph.out_neighbors(dom_tree, :b) == []
      assert Graph.out_neighbors(dom_tree, :c) == []
    end
  end

  describe "dominance frontier" do
    test "diamond: frontier of branches includes join node" do
      g = graph([{:a, :b}, {:a, :c}, {:b, :d}, {:c, :d}])
      idom = Dominator.idom(g, :a)
      df = Dominator.frontier(g, idom)

      assert MapSet.member?(df[:b], :d)
      assert MapSet.member?(df[:c], :d)
      assert df[:a] == MapSet.new()
    end

    test "linear: no dominance frontier" do
      g = graph([{:a, :b}, {:b, :c}])
      idom = Dominator.idom(g, :a)
      df = Dominator.frontier(g, idom)

      assert df[:a] == MapSet.new()
      assert df[:b] == MapSet.new()
      assert df[:c] == MapSet.new()
    end
  end

  describe "dominates?" do
    test "root dominates all" do
      g = graph([{:a, :b}, {:a, :c}, {:b, :d}, {:c, :d}])
      idom = Dominator.idom(g, :a)

      assert Dominator.dominates?(idom, :a, :b)
      assert Dominator.dominates?(idom, :a, :c)
      assert Dominator.dominates?(idom, :a, :d)
    end

    test "node dominates itself" do
      g = graph([{:a, :b}])
      idom = Dominator.idom(g, :a)

      assert Dominator.dominates?(idom, :a, :a)
      assert Dominator.dominates?(idom, :b, :b)
    end

    test "branch does not dominate sibling" do
      g = graph([{:a, :b}, {:a, :c}, {:b, :d}, {:c, :d}])
      idom = Dominator.idom(g, :a)

      refute Dominator.dominates?(idom, :b, :c)
      refute Dominator.dominates?(idom, :c, :b)
    end
  end
end
