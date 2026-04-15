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
          def f(x) do
            case x do
              :a -> 1
              :b -> 2
            end
          end
        end
        """)

      %{control_flow: [mod | _]} = Reach.Visualize.to_graph_json(graph)

      assert mod.module =~ "A"
      assert [func | _] = mod.functions
      assert func.name == "f"
      assert func.arity == 1
      assert is_list(func.blocks.blocks)
      assert is_list(func.blocks.edges)
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
end
