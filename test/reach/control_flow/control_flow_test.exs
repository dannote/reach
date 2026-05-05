defmodule Reach.ControlFlowTest do
  use ExUnit.Case, async: true

  alias Reach.{ControlFlow, IR}
  alias Reach.IR.Node

  defp build_control_flow(source) do
    [func_def] = IR.from_string!(source)
    assert %Node{type: :function_def} = func_def
    cfg = ControlFlow.build(func_def)
    {func_def, cfg}
  end

  defp vertex_ids(cfg) do
    Graph.vertices(cfg) |> MapSet.new()
  end

  defp has_path?(cfg, from, to) do
    Graph.get_shortest_path(cfg, from, to) != nil
  end

  describe "basic structure" do
    test "control flow graph has entry and exit vertices" do
      {_func, cfg} = build_control_flow("def foo, do: 1")
      vertices = vertex_ids(cfg)
      assert :entry in vertices
      assert :exit in vertices
    end

    test "entry is reachable" do
      {_func, cfg} = build_control_flow("def foo, do: 1")
      assert has_path?(cfg, :entry, :exit)
    end
  end

  describe "straight-line code" do
    test "has linear control flow" do
      {_func, cfg} =
        build_control_flow("""
        def foo(x) do
          a = x + 1
          b = a + 2
          b
        end
        """)

      assert has_path?(cfg, :entry, :exit)

      # All non-synthetic vertices should be on one path
      non_synthetic =
        Graph.vertices(cfg)
        |> Enum.filter(&is_integer/1)

      Enum.each(non_synthetic, fn v ->
        assert has_path?(cfg, :entry, v), "#{v} not reachable from :entry"
        assert has_path?(cfg, v, :exit), "#{v} doesn't reach :exit"
      end)
    end
  end

  describe "if/else (desugared to case)" do
    test "creates diamond control flow" do
      {_func, cfg} =
        build_control_flow("""
        def foo(x) do
          if x > 0 do
            :positive
          else
            :negative
          end
        end
        """)

      assert has_path?(cfg, :entry, :exit)

      # Both branches should reach exit
      vertices = Graph.vertices(cfg)

      clause_vertices =
        Enum.filter(vertices, fn
          v when is_integer(v) -> true
          _ -> false
        end)

      Enum.each(clause_vertices, fn v ->
        assert has_path?(cfg, v, :exit), "vertex #{v} doesn't reach :exit"
      end)
    end
  end

  describe "case with multiple clauses" do
    test "creates branching control flow" do
      {_func, cfg} =
        build_control_flow("""
        def foo(x) do
          case x do
            :a -> 1
            :b -> 2
            _ -> 3
          end
        end
        """)

      assert has_path?(cfg, :entry, :exit)

      # Should have clause_match edges
      all_labels =
        Graph.edges(cfg)
        |> Enum.map(& &1.label)

      clause_matches =
        Enum.filter(all_labels, fn
          {:clause_match, _} -> true
          _ -> false
        end)

      assert Enum.count(clause_matches) >= 3
    end
  end

  describe "try/catch" do
    test "creates normal and exception paths" do
      {_func, cfg} =
        build_control_flow("""
        def foo(x) do
          try do
            risky(x)
          rescue
            e in RuntimeError -> handle(e)
          end
        end
        """)

      assert has_path?(cfg, :entry, :exit)

      all_labels =
        Graph.edges(cfg)
        |> Enum.map(& &1.label)

      assert :exception in all_labels
    end

    test "try/after connects after block from all paths" do
      {_func, cfg} =
        build_control_flow("""
        def foo(x) do
          try do
            risky(x)
          rescue
            _ -> :error
          after
            cleanup()
          end
        end
        """)

      assert has_path?(cfg, :entry, :exit)

      all_labels =
        Graph.edges(cfg)
        |> Enum.map(& &1.label)

      assert :after_entry in all_labels
    end
  end

  describe "receive" do
    test "with timeout creates timeout branch" do
      {_func, cfg} =
        build_control_flow("""
        def foo do
          receive do
            {:msg, data} -> data
          after
            5000 -> :timeout
          end
        end
        """)

      assert has_path?(cfg, :entry, :exit)

      all_labels =
        Graph.edges(cfg)
        |> Enum.map(& &1.label)

      assert :timeout in all_labels
    end
  end

  describe "guards" do
    test "guard creates guard_success edge" do
      {_func, cfg} =
        build_control_flow("""
        def foo(x) when is_integer(x) do
          x + 1
        end
        """)

      all_labels =
        Graph.edges(cfg)
        |> Enum.map(& &1.label)

      assert :guard_success in all_labels
    end
  end

  describe "multi-clause function" do
    test "creates dispatch control flow" do
      nodes =
        IR.from_string!("""
        defmodule M do
          def foo(:a), do: 1
          def foo(:b), do: 2
          def foo(_), do: 3
        end
        """)

      # Find all function defs
      func_defs = nodes |> IR.all_nodes() |> Enum.filter(&(&1.type == :function_def))
      assert func_defs != []
    end
  end

  describe "pipe chain" do
    test "is sequential after desugaring" do
      {_func, cfg} =
        build_control_flow("""
        def foo(x) do
          x |> bar() |> baz()
        end
        """)

      assert has_path?(cfg, :entry, :exit)

      # All edges should be sequential (no branching from pipes)
      non_synthetic_edges =
        Graph.edges(cfg)
        |> Enum.filter(fn e -> is_integer(e.v1) and is_integer(e.v2) end)

      Enum.each(non_synthetic_edges, fn e ->
        assert e.label == :sequential, "pipe edge should be sequential, got #{inspect(e.label)}"
      end)
    end
  end

  describe "if without else" do
    test "doesn't crash on missing else branch" do
      {_func, control_flow} =
        build_control_flow("""
        def foo(x) do
          if x > 0 do
            :positive
          end
        end
        """)

      assert has_path?(control_flow, :entry, :exit)
    end
  end

  describe "nested case in function body" do
    test "handles case with literal fallback clause" do
      {_func, control_flow} =
        build_control_flow("""
        def foo(x) do
          case x do
            :a -> 1
            :b -> 2
            _ -> nil
          end
        end
        """)

      assert has_path?(control_flow, :entry, :exit)
    end
  end

  describe "branches nested inside expressions" do
    test "piped if/else — both branches converge at pipe call" do
      {func, cfg} =
        build_control_flow("""
        def foo(x) do
          if x do :a else :b end |> IO.inspect()
        end
        """)

      all_nodes = IR.all_nodes(func)
      call_node = Enum.find(all_nodes, &(&1.type == :call and &1.meta[:function] == :inspect))
      assert call_node, "expected IO.inspect call node"

      true_literal = Enum.find(all_nodes, &(&1.type == :literal and &1.meta[:value] == :a))
      false_literal = Enum.find(all_nodes, &(&1.type == :literal and &1.meta[:value] == :b))

      in_edges = Graph.in_edges(cfg, call_node.id)
      in_sources = MapSet.new(in_edges, & &1.v1)
      assert true_literal.id in in_sources, "true branch should feed into pipe call"
      assert false_literal.id in in_sources, "false branch should feed into pipe call"

      assert has_path?(cfg, true_literal.id, :exit)
      assert has_path?(cfg, false_literal.id, :exit)
    end

    test "assigned case — match node comes after both branches converge" do
      {func, cfg} =
        build_control_flow("""
        def foo(x) do
          result = case x do
            :a -> 1
            :b -> 2
          end
        end
        """)

      all_nodes = IR.all_nodes(func)
      match_node = Enum.find(all_nodes, &(&1.type == :match))
      assert match_node, "expected match node"

      branch_1 = Enum.find(all_nodes, &(&1.type == :literal and &1.meta[:value] == 1))
      branch_2 = Enum.find(all_nodes, &(&1.type == :literal and &1.meta[:value] == 2))

      in_edges = Graph.in_edges(cfg, match_node.id)
      in_sources = MapSet.new(in_edges, & &1.v1)
      assert branch_1.id in in_sources, "first case branch should feed into match"
      assert branch_2.id in in_sources, "second case branch should feed into match"

      assert has_path?(cfg, match_node.id, :exit)
    end

    test "nested if inside case — all inner if branches reach exit" do
      {func, cfg} =
        build_control_flow("""
        def foo(x) do
          case x do
            :a ->
              if x do
                1
              else
                2
              end
            :b -> 3
          end
        end
        """)

      all_nodes = IR.all_nodes(func)

      for val <- [1, 2, 3] do
        node = Enum.find(all_nodes, &(&1.type == :literal and &1.meta[:value] == val))
        assert node, "expected literal #{val}"
        assert has_path?(cfg, node.id, :exit), "literal #{val} doesn't reach :exit"
      end

      assert has_path?(cfg, :entry, :exit)
    end

    test "if piped into case — if condition feeds into case clauses" do
      {func, cfg} =
        build_control_flow("""
        def foo(x) do
          if x do :a else :b end |> case do :a -> 1; :b -> 2 end
        end
        """)

      all_nodes = IR.all_nodes(func)

      if_node = Enum.find(all_nodes, &(&1.type == :case and &1.meta[:desugared_from] == :if))
      assert if_node, "expected if (desugared to case) node"

      case_clauses =
        Enum.filter(all_nodes, &(&1.type == :clause and &1.meta[:kind] == :case_clause))

      assert length(case_clauses) == 2

      for clause <- case_clauses do
        assert has_path?(cfg, if_node.id, clause.id),
               "if node should reach case clause #{clause.id}"

        assert has_path?(cfg, clause.id, :exit),
               "case clause #{clause.id} doesn't reach :exit"
      end
    end

    test "deep nesting — branches inside pipe chain with assignment" do
      {func, cfg} =
        build_control_flow("""
        def foo(x) do
          result = if x do :a else :b end |> IO.inspect() |> String.upcase()
        end
        """)

      all_nodes = IR.all_nodes(func)

      inspect_call =
        Enum.find(all_nodes, &(&1.type == :call and &1.meta[:function] == :inspect))

      upcase_call =
        Enum.find(all_nodes, &(&1.type == :call and &1.meta[:function] == :upcase))

      match_node = Enum.find(all_nodes, &(&1.type == :match))
      true_literal = Enum.find(all_nodes, &(&1.type == :literal and &1.meta[:value] == :a))
      false_literal = Enum.find(all_nodes, &(&1.type == :literal and &1.meta[:value] == :b))

      in_sources = MapSet.new(Graph.in_edges(cfg, inspect_call.id), & &1.v1)
      assert true_literal.id in in_sources, "true branch should converge at IO.inspect"
      assert false_literal.id in in_sources, "false branch should converge at IO.inspect"

      assert has_path?(cfg, inspect_call.id, upcase_call.id)
      assert has_path?(cfg, upcase_call.id, match_node.id)
      assert has_path?(cfg, match_node.id, :exit)
    end
  end
end
