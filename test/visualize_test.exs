defmodule Reach.VisualizeTest do
  use ExUnit.Case, async: true

  describe "to_graph_json/2" do
    test "produces all three modes" do
      graph =
        Reach.string_to_graph!("""
        defmodule MyMod do
          def greet(name) do
            IO.puts(name)
          end
        end
        """)

      result = Reach.Visualize.to_graph_json(graph)

      assert is_list(result.control_flow)
      assert is_map(result.call_graph)
      assert is_map(result.data_flow)
    end

    test "control flow has modules with functions and blocks" do
      graph =
        Reach.string_to_graph!("""
        defmodule A do
          def f(x), do: x
        end
        """)

      %{control_flow: [mod | _]} = Reach.Visualize.to_graph_json(graph)

      assert mod.module =~ "A"
      assert [func | _] = mod.functions
      assert func.name == "f"
      assert func.arity == 1
      assert is_list(func.nodes)
      assert is_list(func.edges)
    end

    test "call graph has modules and edges" do
      graph =
        Reach.string_to_graph!("""
        defmodule B do
          def caller, do: callee()
          def callee, do: :ok
        end
        """)

      %{call_graph: cg} = Reach.Visualize.to_graph_json(graph)

      assert is_list(cg.modules)
      assert is_list(cg.edges)
      assert cg.modules != []
    end

    test "data flow has functions and edges" do
      graph =
        Reach.string_to_graph!("""
        defmodule C do
          def f(x), do: g(x)
          def g(y), do: y
        end
        """)

      %{data_flow: df} = Reach.Visualize.to_graph_json(graph)

      assert is_list(df.functions)
      assert is_list(df.edges)
      assert is_list(df.taint_paths)
    end
  end

  describe "to_json/2" do
    test "returns valid JSON string" do
      graph =
        Reach.string_to_graph!("""
        defmodule G do
          def f(x), do: x
        end
        """)

      json = Reach.Visualize.to_json(graph)
      assert is_binary(json)
      assert {:ok, parsed} = Jason.decode(json)
      assert is_list(parsed["control_flow"])
    end
  end

  describe "struct and map pattern rendering" do
    # Regression: the :map and :struct render_pattern clauses used to split
    # children with Enum.chunk_every(2), but the IR actually wraps each pair
    # in a :map_field node — so render_map_pair/1 was handed a single-element
    # list and raised FunctionClauseError for any pattern like %Date{year: y}.
    alias Reach.IR.Node
    alias Reach.Visualize.Helpers

    test "renders a struct pattern with a single field binding" do
      year_key = %Node{id: 1, type: :literal, meta: %{value: :year}}
      y_var = %Node{id: 2, type: :var, meta: %{name: :y}}
      field = %Node{id: 3, type: :map_field, children: [year_key, y_var]}
      struct_node = %Node{id: 4, type: :struct, meta: %{name: Date}, children: [field]}

      assert Helpers.render_pattern(struct_node) == "%Date{year: y}"
    end

    test "renders a struct pattern with multiple field bindings" do
      k1 = %Node{id: 1, type: :literal, meta: %{value: :a}}
      v1 = %Node{id: 2, type: :var, meta: %{name: :x}}
      k2 = %Node{id: 3, type: :literal, meta: %{value: :b}}
      v2 = %Node{id: 4, type: :var, meta: %{name: :y}}
      f1 = %Node{id: 5, type: :map_field, children: [k1, v1]}
      f2 = %Node{id: 6, type: :map_field, children: [k2, v2]}
      struct_node = %Node{id: 7, type: :struct, meta: %{name: MyApp.User}, children: [f1, f2]}

      assert Helpers.render_pattern(struct_node) == "%MyApp.User{a: x, b: y}"
    end

    test "renders a map pattern with field bindings" do
      k = %Node{id: 1, type: :literal, meta: %{value: :year}}
      v = %Node{id: 2, type: :var, meta: %{name: :y}}
      field = %Node{id: 3, type: :map_field, children: [k, v]}
      map_node = %Node{id: 4, type: :map, children: [field]}

      assert Helpers.render_pattern(map_node) == "%{year: y}"
    end

    test "to_graph_json does not crash on code with a struct pattern" do
      graph =
        Reach.string_to_graph!("""
        defmodule StructPattern do
          def test(value) do
            case value do
              %Date{year: y} -> y
              _ -> nil
            end
          end
        end
        """)

      assert %{control_flow: _} = Reach.Visualize.to_graph_json(graph)
    end

    test "to_json does not crash on code with a nested struct pattern" do
      graph =
        Reach.string_to_graph!("""
        defmodule NestedStructPattern do
          def test(value) do
            case value do
              {:ok, %Date{year: y}} -> y
              _ -> nil
            end
          end
        end
        """)

      assert is_binary(Reach.Visualize.to_json(graph))
    end
  end
end
