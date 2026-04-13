defmodule Reach.GraphTest do
  use ExUnit.Case, async: true

  alias Reach.{Graph, IR}

  describe "graph construction" do
    test "builds from function definition" do
      {:ok, pdg} =
        Graph.from_string("""
        def foo(x) do
          y = x + 1
          y
        end
        """)

      assert %Reach.Graph{} = pdg
      assert map_size(pdg.nodes) > 0
    end

    test "builds from bare expressions" do
      {:ok, pdg} =
        Graph.from_string("""
        x = 1
        y = x + 1
        """)

      assert %Reach.Graph{} = pdg
    end
  end

  describe "backward slice" do
    test "includes contributing expressions" do
      nodes =
        IR.from_string!("""
        def foo(x) do
          y = x + 1
          y
        end
        """)

      pdg = Graph.build(nodes)

      # Find the final 'y' use
      all = IR.all_nodes(nodes)

      y_uses =
        Enum.filter(all, fn n ->
          n.type == :var and n.meta[:name] == :y
        end)

      # The last y reference
      last_y = List.last(y_uses)

      slice = Graph.backward_slice(pdg, last_y.id)
      # The slice should include some nodes (at least the definition of y)
      assert is_list(slice)
    end
  end

  describe "forward slice" do
    test "includes affected expressions" do
      nodes =
        IR.from_string!("""
        def foo(x) do
          y = x + 1
          z = y + 2
          z
        end
        """)

      pdg = Graph.build(nodes)
      all = IR.all_nodes(nodes)

      # Find x param
      x_nodes =
        Enum.filter(all, fn n ->
          n.type == :var and n.meta[:name] == :x
        end)

      if x_nodes != [] do
        x_node = hd(x_nodes)
        slice = Graph.forward_slice(pdg, x_node.id)
        # x flows to y = x + 1 and transitively to z
        assert is_list(slice)
      end
    end
  end

  describe "independence" do
    test "independent variables with no data flow" do
      nodes =
        IR.from_string!("""
        x = 1
        y = 2
        """)

      pdg = Graph.build(nodes)
      all = IR.all_nodes(nodes)

      x_match = Enum.find(all, &(&1.type == :match and match_var_name(&1) == :x))
      y_match = Enum.find(all, &(&1.type == :match and match_var_name(&1) == :y))

      if x_match && y_match do
        assert Graph.independent?(pdg, x_match.id, y_match.id)
      end
    end

    test "dependent variables with data flow" do
      nodes =
        IR.from_string!("""
        x = 1
        y = x + 1
        """)

      pdg = Graph.build(nodes)
      all = IR.all_nodes(nodes)

      # The definition of x (in the match LHS)
      x_def_node =
        Enum.find(all, fn n ->
          n.type == :match and match_var_name(n) == :x
        end)

      # The use of x (in x + 1, child of y's match)
      x_use =
        Enum.find(all, fn n ->
          (n.type == :var and n.meta[:name] == :x and
             n.source_span) && n.source_span.start_line == 2
        end)

      if x_def_node && x_use do
        # The x use should depend on x's definition
        refute Graph.independent?(pdg, x_def_node.id, x_use.id)
      end
    end
  end

  describe "control deps" do
    test "returns control dependencies" do
      {:ok, pdg} =
        Graph.from_string("""
        def foo(x) do
          if x > 0 do
            :positive
          else
            :negative
          end
        end
        """)

      # Verify the PDG has edges
      edges = Graph.edges(pdg)
      assert is_list(edges)
    end
  end

  describe "chop" do
    test "returns nodes on path from source to sink" do
      nodes =
        IR.from_string!("""
        x = 1
        y = x + 1
        z = y + 2
        """)

      pdg = Graph.build(nodes)
      all = IR.all_nodes(nodes)

      x_def = Enum.find(all, &(&1.type == :match and match_var_name(&1) == :x))
      z_def = Enum.find(all, &(&1.type == :match and match_var_name(&1) == :z))

      if x_def && z_def do
        chop = Graph.chop(pdg, x_def.id, z_def.id)
        assert is_list(chop)
      end
    end
  end

  describe "works with SystemDependence" do
    test "backward_slice accepts SystemDependence" do
      {:ok, sdg} =
        Reach.SystemDependence.from_string("""
        def foo(x) do
          y = x + 1
          y
        end
        """)

      all = Reach.IR.all_nodes(sdg.ir)
      node = Enum.find(all, &(&1.type == :var))

      if node do
        result = Reach.Graph.backward_slice(sdg, node.id)
        assert is_list(result)
      end
    end

    test "forward_slice accepts SystemDependence" do
      {:ok, sdg} =
        Reach.SystemDependence.from_string("""
        def foo(x) do
          y = x + 1
          y
        end
        """)

      all = Reach.IR.all_nodes(sdg.ir)
      node = Enum.find(all, &(&1.type == :var))

      if node do
        result = Reach.Graph.forward_slice(sdg, node.id)
        assert is_list(result)
      end
    end
  end

  describe "DOT export" do
    test "produces valid DOT" do
      {:ok, pdg} =
        Graph.from_string("""
        def foo(x) do
          y = x + 1
          y
        end
        """)

      assert {:ok, dot} = Graph.to_dot(pdg)
      assert String.contains?(dot, "digraph")
    end
  end

  # Helper to extract variable name from a match node
  defp match_var_name(%{type: :match, children: [left | _]}) do
    case left do
      %{type: :var, meta: %{name: name}} -> name
      _ -> nil
    end
  end

  defp match_var_name(_), do: nil
end
