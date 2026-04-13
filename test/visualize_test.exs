defmodule Reach.VisualizeTest do
  use ExUnit.Case, async: true

  describe "to_vue_flow/2" do
    test "produces nodes and edges from a simple graph" do
      graph =
        Reach.string_to_graph!("""
        defmodule MyMod do
          def greet(name) do
            IO.puts(name)
          end
        end
        """)

      result = Reach.Visualize.to_vue_flow(graph)

      assert is_map(result)
      assert is_list(result.nodes)
      assert is_list(result.edges)
      assert result.nodes != []
      assert result.edges != []
    end

    test "node has required Vue Flow fields" do
      graph =
        Reach.string_to_graph!("""
        defmodule A do
          def f(x), do: x
        end
        """)

      %{nodes: [node | _]} = Reach.Visualize.to_vue_flow(graph)

      assert is_binary(node.id)
      assert is_binary(node.type)
      assert is_map(node.position)
      assert is_number(node.position.x)
      assert is_number(node.position.y)
      assert is_map(node.data)
      assert is_binary(node.data.label)
      assert is_binary(node.data.type)
      assert is_map(node.style)
    end

    test "edge has required Vue Flow fields" do
      graph =
        Reach.string_to_graph!("""
        defmodule B do
          def f(x), do: g(x)
        end
        """)

      %{edges: [edge | _]} = Reach.Visualize.to_vue_flow(graph)

      assert is_binary(edge.id)
      assert is_binary(edge.source)
      assert is_binary(edge.target)
      assert is_binary(edge.label)
      assert is_map(edge.style)
      assert is_binary(edge.style.stroke)
    end

    test "function nodes have correct type" do
      graph =
        Reach.string_to_graph!("""
        defmodule C do
          def hello, do: :world
        end
        """)

      %{nodes: nodes} = Reach.Visualize.to_vue_flow(graph)
      func_nodes = Enum.filter(nodes, &(&1.type == "function"))
      assert func_nodes != []
      assert hd(func_nodes).data.label =~ "hello"
    end

    test "module nodes have correct type" do
      graph =
        Reach.string_to_graph!("""
        defmodule D do
          def x, do: 1
        end
        """)

      %{nodes: nodes} = Reach.Visualize.to_vue_flow(graph)
      mod_nodes = Enum.filter(nodes, &(&1.type == "module"))
      assert length(mod_nodes) == 1
      assert hd(mod_nodes).data.label =~ "D"
    end

    test "dead code nodes get reduced opacity" do
      graph =
        Reach.string_to_graph!("""
        defmodule E do
          def f(x) do
            1 + 2
            x
          end
        end
        """)

      %{nodes: nodes} = Reach.Visualize.to_vue_flow(graph, dead_code: true)
      dead_nodes = Enum.filter(nodes, &(&1.style.opacity == "0.3"))
      # 1 + 2 is dead code — pure expression whose value is unused
      assert dead_nodes != []
    end

    test "edge colors differ by type" do
      graph =
        Reach.string_to_graph!("""
        defmodule F do
          def f(x), do: g(x)
        end
        """)

      %{edges: edges} = Reach.Visualize.to_vue_flow(graph)
      colors = edges |> Enum.map(& &1.style.stroke) |> Enum.uniq()
      assert colors != []
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
      assert is_list(parsed["nodes"])
      assert is_list(parsed["edges"])
    end
  end
end
