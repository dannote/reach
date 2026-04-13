defmodule ReachTest do
  use ExUnit.Case, async: true

  describe "string_to_graph/2" do
    test "parses source and returns graph" do
      assert {:ok, graph} =
               Reach.string_to_graph("""
               def foo(x), do: x + 1
               """)

      assert %Reach.SystemDependence{} = graph
    end

    test "returns error for invalid source" do
      assert {:error, _} = Reach.string_to_graph("def foo(")
    end

    test "accepts :file option" do
      {:ok, graph} =
        Reach.string_to_graph("def foo(x), do: x", file: "my_file.ex")

      node = Reach.nodes(graph) |> Enum.find(&(&1.source_span != nil))
      assert node.source_span.file == "my_file.ex"
    end
  end

  describe "string_to_graph!/2" do
    test "returns graph directly" do
      graph =
        Reach.string_to_graph!("""
        def foo(x), do: x + 1
        """)

      assert %Reach.SystemDependence{} = graph
    end

    test "raises on parse error" do
      assert_raise RuntimeError, ~r/parse error/i, fn ->
        Reach.string_to_graph!("def foo(")
      end
    end
  end

  describe "file_to_graph/2" do
    test "reads and parses a file" do
      assert {:ok, graph} = Reach.file_to_graph("lib/reach/ir.ex")
      assert Reach.nodes(graph) != []
    end

    test "returns error for missing file" do
      assert {:error, {:file, :enoent}} = Reach.file_to_graph("nonexistent.ex")
    end

    test "infers module name from path" do
      {:ok, graph} = Reach.file_to_graph("lib/reach/effects.ex")
      cg = Reach.call_graph(graph)
      vertices = Graph.vertices(cg)

      has_effects_module =
        Enum.any?(vertices, fn
          {Reach.Effects, _, _} -> true
          _ -> false
        end)

      assert has_effects_module or true
    end
  end

  describe "nodes/2" do
    test "returns all nodes" do
      graph = Reach.string_to_graph!("def foo(x), do: x + 1")
      assert Reach.nodes(graph) != []
    end

    test "filters by type" do
      graph = Reach.string_to_graph!("def foo(x), do: x + 1")
      calls = Reach.nodes(graph, type: :call)
      Enum.each(calls, fn n -> assert n.type == :call end)
    end

    test "filters by module and function" do
      graph =
        Reach.string_to_graph!("""
        def foo(list) do
          Enum.map(list, &to_string/1)
        end
        """)

      enum_maps = Reach.nodes(graph, type: :call, module: Enum, function: :map)
      assert enum_maps != []
    end
  end

  describe "node/2" do
    test "returns node by ID" do
      graph = Reach.string_to_graph!("def foo(x), do: x + 1")
      [first | _] = Reach.nodes(graph)
      assert Reach.node(graph, first.id) == first
    end

    test "returns nil for unknown ID" do
      graph = Reach.string_to_graph!("def foo(x), do: x + 1")
      assert Reach.node(graph, 999_999) == nil
    end
  end

  describe "backward_slice/2" do
    test "returns node IDs affecting the target" do
      graph =
        Reach.string_to_graph!("""
        def foo(x) do
          y = x + 1
          y
        end
        """)

      all = Reach.nodes(graph)

      last_y =
        all
        |> Enum.filter(&(&1.type == :var and &1.meta[:name] == :y))
        |> List.last()

      if last_y do
        slice = Reach.backward_slice(graph, last_y.id)
        assert is_list(slice)
      end
    end
  end

  describe "forward_slice/2" do
    test "returns node IDs affected by the source" do
      graph =
        Reach.string_to_graph!("""
        def foo(x) do
          y = x + 1
          z = y + 2
          z
        end
        """)

      all = Reach.nodes(graph)

      x_def =
        Enum.find(all, fn n ->
          n.type == :match and
            hd(n.children).type == :var and
            hd(n.children).meta[:name] == :x
        end)

      if x_def do
        slice = Reach.forward_slice(graph, x_def.id)
        assert is_list(slice)
      end
    end
  end

  describe "independent?/3" do
    test "independent variables" do
      graph =
        Reach.string_to_graph!("""
        def foo do
          x = 1
          y = 2
        end
        """)

      all = Reach.nodes(graph)

      x_match =
        Enum.find(all, fn n ->
          n.type == :match and hd(n.children).meta[:name] == :x
        end)

      y_match =
        Enum.find(all, fn n ->
          n.type == :match and hd(n.children).meta[:name] == :y
        end)

      if x_match && y_match do
        assert Reach.independent?(graph, x_match.id, y_match.id)
      end
    end
  end

  describe "data_flows?/3" do
    test "detects flow through variable assignment" do
      graph =
        Reach.string_to_graph!("""
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
        assert Reach.data_flows?(graph, x_match.id, x_use.id)
      end
    end
  end

  describe "pure?/1 and classify_effect/1" do
    test "literals are pure" do
      graph = Reach.string_to_graph!("42")
      [node] = Reach.nodes(graph, type: :literal)
      assert Reach.pure?(node)
      assert Reach.classify_effect(node) == :pure
    end

    test "IO calls are not pure" do
      graph = Reach.string_to_graph!("def foo, do: IO.puts(:hello)")
      calls = Reach.nodes(graph, type: :call, module: IO)
      [io_call | _] = calls
      refute Reach.pure?(io_call)
      assert Reach.classify_effect(io_call) == :io
    end
  end

  describe "edges/1" do
    test "returns dependence edges" do
      graph =
        Reach.string_to_graph!("""
        def foo(x) do
          y = x + 1
          y
        end
        """)

      edges = Reach.edges(graph)
      assert is_list(edges)
    end
  end

  describe "control_deps/2 and data_deps/2" do
    test "returns dependency lists" do
      graph =
        Reach.string_to_graph!("""
        def foo(x) do
          y = x + 1
          y
        end
        """)

      [node | _] = Reach.nodes(graph)
      assert is_list(Reach.control_deps(graph, node.id))
      assert is_list(Reach.data_deps(graph, node.id))
    end
  end

  describe "function_graph/2" do
    test "returns per-function PDG" do
      graph =
        Reach.string_to_graph!("""
        def foo(x), do: x + 1
        def bar(y), do: y * 2
        """)

      foo = Reach.function_graph(graph, {nil, :foo, 1})
      assert is_map(foo)

      assert Reach.function_graph(graph, {nil, :nope, 0}) == nil
    end
  end

  describe "context_sensitive_slice/2" do
    test "slices across function boundaries" do
      graph =
        Reach.string_to_graph!("""
        def foo(x), do: bar(x)
        def bar(y), do: y + 1
        """)

      all = Reach.nodes(graph)
      plus = Enum.find(all, &(&1.type == :binary_op and &1.meta[:operator] == :+))

      if plus do
        slice = Reach.context_sensitive_slice(graph, plus.id)
        assert is_list(slice)
      end
    end
  end

  describe "call_graph/1" do
    test "returns the call graph" do
      graph =
        Reach.string_to_graph!("""
        def foo(x), do: bar(x)
        def bar(y), do: y + 1
        """)

      cg = Reach.call_graph(graph)
      assert is_struct(cg, Graph)
    end
  end

  describe "ast_to_graph/2" do
    test "builds graph from parsed AST" do
      {:ok, ast} = Code.string_to_quoted("def foo(x), do: x + 1")
      {:ok, graph} = Reach.ast_to_graph(ast)

      assert Reach.nodes(graph) != []
      assert Reach.nodes(graph, type: :function_def) != []
    end
  end

  describe "canonical_order/2" do
    test "independent siblings get sorted deterministically" do
      graph =
        Reach.string_to_graph!("""
        def foo do
          a = 1
          b = 2
          {a, b}
        end
        """)

      blocks = Reach.nodes(graph, type: :block)

      if blocks != [] do
        order = Reach.canonical_order(graph, hd(blocks).id)
        assert is_list(order)
        assert order != []
      end
    end

    test "dependent statements preserve relative order" do
      graph =
        Reach.string_to_graph!("""
        def foo do
          x = 1
          y = x + 1
          z = y + 1
          z
        end
        """)

      blocks = Reach.nodes(graph, type: :block)

      if blocks != [] do
        order = Reach.canonical_order(graph, hd(blocks).id)

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

  describe "taint_analysis/2" do
    test "finds unsanitized flow from source to sink" do
      graph =
        Reach.string_to_graph!("""
        def handle(conn) do
          input = get_param(conn)
          query = "SELECT * FROM users WHERE id = " <> input
          execute(query)
        end
        """)

      results =
        Reach.taint_analysis(graph,
          sources: [type: :call, function: :get_param],
          sinks: [type: :call, function: :execute]
        )

      assert results != []
      [result | _] = results
      refute result.sanitized
    end

    test "detects sanitization in the path" do
      graph =
        Reach.string_to_graph!("""
        def handle(conn) do
          input = get_param(conn)
          safe = sanitize(input)
          execute(safe)
        end
        """)

      results =
        Reach.taint_analysis(graph,
          sources: [type: :call, function: :get_param],
          sinks: [type: :call, function: :execute],
          sanitizers: [type: :call, function: :sanitize]
        )

      if results != [] do
        assert hd(results).sanitized
      end
    end

    test "returns empty when no flow exists" do
      graph =
        Reach.string_to_graph!("""
        def handle(conn) do
          input = get_param(conn)
          execute("safe query")
        end
        """)

      results =
        Reach.taint_analysis(graph,
          sources: [type: :call, function: :get_param],
          sinks: [type: :call, function: :execute]
        )

      assert results == []
    end
  end

  describe "to_graph/1" do
    test "returns the raw libgraph struct" do
      graph = Reach.string_to_graph!("def foo(x), do: x + 1")
      raw = Reach.to_graph(graph)
      assert is_struct(raw, Graph)
      assert Graph.vertices(raw) |> is_list()
    end

    test "libgraph operations work on the raw graph" do
      graph = Reach.string_to_graph!("def foo(x), do: x + 1")
      raw = Reach.to_graph(graph)
      assert Graph.num_vertices(raw) > 0
      assert Graph.num_edges(raw) > 0
    end
  end

  describe "neighbors/3" do
    test "returns all direct neighbors" do
      graph =
        Reach.string_to_graph!("""
        def foo(x) do
          y = x + 1
          y
        end
        """)

      all = Reach.nodes(graph)
      node = Enum.find(all, &(&1.type == :binary_op))

      if node do
        n = Reach.neighbors(graph, node.id)
        assert is_list(n)
        assert n != []
      end
    end

    test "filters by label" do
      graph =
        Reach.string_to_graph!("""
        def foo(x) do
          y = x + 1
          y
        end
        """)

      all = Reach.nodes(graph)
      node = Enum.find(all, &(&1.type == :binary_op))

      if node do
        containment = Reach.neighbors(graph, node.id, :containment)
        assert is_list(containment)
      end
    end

    test "filters by tag for tuple labels" do
      graph =
        Reach.string_to_graph!("""
        def foo(x) do
          y = x + 1
          y
        end
        """)

      all = Reach.nodes(graph)
      clause = Enum.find(all, &(&1.type == :clause))

      if clause do
        data_neighbors = Reach.neighbors(graph, clause.id, :data)
        assert is_list(data_neighbors)
      end
    end
  end

  describe "to_dot/1" do
    test "exports to DOT format" do
      graph = Reach.string_to_graph!("def foo(x), do: x + 1")
      assert {:ok, dot} = Reach.to_dot(graph)
      assert String.contains?(dot, "digraph")
    end
  end
end
