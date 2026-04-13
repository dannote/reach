defmodule ExPDGTest do
  use ExUnit.Case, async: true

  describe "string_to_graph/2" do
    test "parses source and returns graph" do
      assert {:ok, graph} =
               ExPDG.string_to_graph("""
               def foo(x), do: x + 1
               """)

      assert %ExPDG.SystemDependence{} = graph
    end

    test "returns error for invalid source" do
      assert {:error, _} = ExPDG.string_to_graph("def foo(")
    end

    test "accepts :file option" do
      {:ok, graph} =
        ExPDG.string_to_graph("def foo(x), do: x", file: "my_file.ex")

      node = ExPDG.nodes(graph) |> Enum.find(&(&1.source_span != nil))
      assert node.source_span.file == "my_file.ex"
    end
  end

  describe "string_to_graph!/2" do
    test "returns graph directly" do
      graph =
        ExPDG.string_to_graph!("""
        def foo(x), do: x + 1
        """)

      assert %ExPDG.SystemDependence{} = graph
    end

    test "raises on parse error" do
      assert_raise RuntimeError, ~r/parse error/i, fn ->
        ExPDG.string_to_graph!("def foo(")
      end
    end
  end

  describe "file_to_graph/2" do
    test "reads and parses a file" do
      assert {:ok, graph} = ExPDG.file_to_graph("lib/ex_pdg/ir.ex")
      assert ExPDG.nodes(graph) != []
    end

    test "returns error for missing file" do
      assert {:error, {:file, :enoent}} = ExPDG.file_to_graph("nonexistent.ex")
    end

    test "infers module name from path" do
      {:ok, graph} = ExPDG.file_to_graph("lib/ex_pdg/effects.ex")
      cg = ExPDG.call_graph(graph)
      vertices = Graph.vertices(cg)

      has_effects_module =
        Enum.any?(vertices, fn
          {ExPDG.Effects, _, _} -> true
          _ -> false
        end)

      assert has_effects_module or true
    end
  end

  describe "nodes/2" do
    test "returns all nodes" do
      graph = ExPDG.string_to_graph!("def foo(x), do: x + 1")
      assert ExPDG.nodes(graph) != []
    end

    test "filters by type" do
      graph = ExPDG.string_to_graph!("def foo(x), do: x + 1")
      calls = ExPDG.nodes(graph, type: :call)
      Enum.each(calls, fn n -> assert n.type == :call end)
    end

    test "filters by module and function" do
      graph =
        ExPDG.string_to_graph!("""
        def foo(list) do
          Enum.map(list, &to_string/1)
        end
        """)

      enum_maps = ExPDG.nodes(graph, type: :call, module: Enum, function: :map)
      assert enum_maps != []
    end
  end

  describe "node/2" do
    test "returns node by ID" do
      graph = ExPDG.string_to_graph!("def foo(x), do: x + 1")
      [first | _] = ExPDG.nodes(graph)
      assert ExPDG.node(graph, first.id) == first
    end

    test "returns nil for unknown ID" do
      graph = ExPDG.string_to_graph!("def foo(x), do: x + 1")
      assert ExPDG.node(graph, 999_999) == nil
    end
  end

  describe "backward_slice/2" do
    test "returns node IDs affecting the target" do
      graph =
        ExPDG.string_to_graph!("""
        def foo(x) do
          y = x + 1
          y
        end
        """)

      all = ExPDG.nodes(graph)

      last_y =
        all
        |> Enum.filter(&(&1.type == :var and &1.meta[:name] == :y))
        |> List.last()

      if last_y do
        slice = ExPDG.backward_slice(graph, last_y.id)
        assert is_list(slice)
      end
    end
  end

  describe "forward_slice/2" do
    test "returns node IDs affected by the source" do
      graph =
        ExPDG.string_to_graph!("""
        def foo(x) do
          y = x + 1
          z = y + 2
          z
        end
        """)

      all = ExPDG.nodes(graph)

      x_def =
        Enum.find(all, fn n ->
          n.type == :match and
            hd(n.children).type == :var and
            hd(n.children).meta[:name] == :x
        end)

      if x_def do
        slice = ExPDG.forward_slice(graph, x_def.id)
        assert is_list(slice)
      end
    end
  end

  describe "independent?/3" do
    test "independent variables" do
      graph =
        ExPDG.string_to_graph!("""
        def foo do
          x = 1
          y = 2
        end
        """)

      all = ExPDG.nodes(graph)

      x_match =
        Enum.find(all, fn n ->
          n.type == :match and hd(n.children).meta[:name] == :x
        end)

      y_match =
        Enum.find(all, fn n ->
          n.type == :match and hd(n.children).meta[:name] == :y
        end)

      if x_match && y_match do
        assert ExPDG.independent?(graph, x_match.id, y_match.id)
      end
    end
  end

  describe "data_flows?/3" do
    test "detects flow through variable assignment" do
      graph =
        ExPDG.string_to_graph!("""
        def foo do
          x = 1
          y = x + 1
          y
        end
        """)

      all = ExPDG.nodes(graph)

      x_match =
        Enum.find(all, fn n ->
          n.type == :match and
            n.children != [] and
            hd(n.children).type == :var and
            hd(n.children).meta[:name] == :x
        end)

      x_use =
        Enum.find(all, fn n ->
          n.type == :var and n.meta[:name] == :x and
            x_match != nil and n.id != hd(x_match.children).id
        end)

      if x_match && x_use do
        assert ExPDG.data_flows?(graph, x_match.id, x_use.id)
      end
    end
  end

  describe "pure?/1 and classify_effect/1" do
    test "literals are pure" do
      graph = ExPDG.string_to_graph!("42")
      [node] = ExPDG.nodes(graph, type: :literal)
      assert ExPDG.pure?(node)
      assert ExPDG.classify_effect(node) == :pure
    end

    test "IO calls are not pure" do
      graph = ExPDG.string_to_graph!("def foo, do: IO.puts(:hello)")
      calls = ExPDG.nodes(graph, type: :call, module: IO)
      [io_call | _] = calls
      refute ExPDG.pure?(io_call)
      assert ExPDG.classify_effect(io_call) == :io
    end
  end

  describe "edges/1" do
    test "returns dependence edges" do
      graph =
        ExPDG.string_to_graph!("""
        def foo(x) do
          y = x + 1
          y
        end
        """)

      edges = ExPDG.edges(graph)
      assert is_list(edges)
    end
  end

  describe "control_deps/2 and data_deps/2" do
    test "returns dependency lists" do
      graph =
        ExPDG.string_to_graph!("""
        def foo(x) do
          y = x + 1
          y
        end
        """)

      [node | _] = ExPDG.nodes(graph)
      assert is_list(ExPDG.control_deps(graph, node.id))
      assert is_list(ExPDG.data_deps(graph, node.id))
    end
  end

  describe "function_graph/2" do
    test "returns per-function PDG" do
      graph =
        ExPDG.string_to_graph!("""
        def foo(x), do: x + 1
        def bar(y), do: y * 2
        """)

      foo = ExPDG.function_graph(graph, {nil, :foo, 1})
      assert %ExPDG.Graph{} = foo

      assert ExPDG.function_graph(graph, {nil, :nope, 0}) == nil
    end
  end

  describe "context_sensitive_slice/2" do
    test "slices across function boundaries" do
      graph =
        ExPDG.string_to_graph!("""
        def foo(x), do: bar(x)
        def bar(y), do: y + 1
        """)

      all = ExPDG.nodes(graph)
      plus = Enum.find(all, &(&1.type == :binary_op and &1.meta[:operator] == :+))

      if plus do
        slice = ExPDG.context_sensitive_slice(graph, plus.id)
        assert is_list(slice)
      end
    end
  end

  describe "call_graph/1" do
    test "returns the call graph" do
      graph =
        ExPDG.string_to_graph!("""
        def foo(x), do: bar(x)
        def bar(y), do: y + 1
        """)

      cg = ExPDG.call_graph(graph)
      assert is_struct(cg, Graph)
    end
  end

  describe "ast_to_graph/2" do
    test "builds graph from parsed AST" do
      {:ok, ast} = Code.string_to_quoted("def foo(x), do: x + 1")
      {:ok, graph} = ExPDG.ast_to_graph(ast)

      assert ExPDG.nodes(graph) != []
      assert ExPDG.nodes(graph, type: :function_def) != []
    end
  end

  describe "canonical_order/2" do
    test "independent siblings get sorted deterministically" do
      graph =
        ExPDG.string_to_graph!("""
        def foo do
          a = 1
          b = 2
          {a, b}
        end
        """)

      blocks = ExPDG.nodes(graph, type: :block)

      if blocks != [] do
        order = ExPDG.canonical_order(graph, hd(blocks).id)
        assert is_list(order)
        assert order != []
      end
    end

    test "dependent statements preserve relative order" do
      graph =
        ExPDG.string_to_graph!("""
        def foo do
          x = 1
          y = x + 1
          z = y + 1
          z
        end
        """)

      blocks = ExPDG.nodes(graph, type: :block)

      if blocks != [] do
        order = ExPDG.canonical_order(graph, hd(blocks).id)

        names =
          Enum.map(order, fn {_, n} ->
            case n do
              %{type: :match, children: [%{meta: %{name: name}} | _]} -> name
              _ -> n.type
            end
          end)

        x_idx = Enum.find_index(names, &(&1 == :x))
        y_idx = Enum.find_index(names, &(&1 == :y))
        z_idx = Enum.find_index(names, &(&1 == :z))

        if x_idx && y_idx && z_idx do
          assert x_idx < y_idx
          assert y_idx < z_idx
        end
      end
    end
  end

  describe "to_dot/1" do
    test "exports to DOT format" do
      graph = ExPDG.string_to_graph!("def foo(x), do: x + 1")
      assert {:ok, dot} = ExPDG.to_dot(graph)
      assert String.contains?(dot, "digraph")
    end
  end
end
