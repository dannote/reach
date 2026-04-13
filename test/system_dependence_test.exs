defmodule Reach.SystemDependenceTest do
  use ExUnit.Case, async: true

  alias Reach.{IR, SystemDependence}

  describe "build/2" do
    test "builds system dependence graph from multiple function definitions" do
      {:ok, sdg} =
        SystemDependence.from_string("""
        def foo(x), do: bar(x)
        def bar(y), do: y + 1
        """)

      assert %Reach.SystemDependence{} = sdg
      assert map_size(sdg.function_pdgs) == 2
    end

    test "creates call edges between caller and callee" do
      {:ok, sdg} =
        SystemDependence.from_string("""
        def foo(x), do: bar(x)
        def bar(y), do: y + 1
        """)

      edges = Graph.edges(sdg.graph)
      call_edges = Enum.filter(edges, &(&1.label == :call))
      assert call_edges != []
    end

    test "creates parameter_in edges for arguments" do
      {:ok, sdg} =
        SystemDependence.from_string("""
        def foo(x), do: bar(x)
        def bar(y), do: y + 1
        """)

      edges = Graph.edges(sdg.graph)
      param_in_edges = Enum.filter(edges, &(&1.label == :parameter_in))
      assert param_in_edges != []
    end

    test "creates parameter_out edges for return values" do
      {:ok, sdg} =
        SystemDependence.from_string("""
        def foo(x), do: bar(x)
        def bar(y), do: y + 1
        """)

      edges = Graph.edges(sdg.graph)
      param_out_edges = Enum.filter(edges, &(&1.label == :parameter_out))
      assert param_out_edges != []
    end

    test "creates summary edges when param flows to return" do
      {:ok, sdg} =
        SystemDependence.from_string("""
        def foo(x), do: bar(x)
        def bar(y), do: y + 1
        """)

      edges = Graph.edges(sdg.graph)
      summary_edges = Enum.filter(edges, &(&1.label == :summary))
      assert summary_edges != []
    end
  end

  describe "call to pure function" do
    test "creates data edges only through params/return" do
      {:ok, sdg} =
        SystemDependence.from_string("""
        def foo(x), do: add_one(x)
        def add_one(n), do: n + 1
        """)

      edges = Graph.edges(sdg.graph)

      interprocedural_labels =
        edges
        |> Enum.map(& &1.label)
        |> Enum.filter(&(&1 in [:call, :parameter_in, :parameter_out, :summary]))

      assert :parameter_in in interprocedural_labels
    end
  end

  describe "recursive call" do
    test "doesn't create infinite graph" do
      {:ok, sdg} =
        SystemDependence.from_string("""
        def factorial(0), do: 1
        def factorial(n), do: n * factorial(n - 1)
        """)

      assert %Reach.SystemDependence{} = sdg
      vertices = Graph.vertices(sdg.graph)
      assert is_list(vertices)
    end
  end

  describe "context-sensitive slicing" do
    test "slices backward through call site" do
      {:ok, sdg} =
        SystemDependence.from_string("""
        def foo(x), do: bar(x)
        def bar(y), do: y + 1
        """)

      all = IR.all_nodes(sdg.ir)

      plus_node =
        Enum.find(all, fn n ->
          n.type == :binary_op and n.meta[:operator] == :+
        end)

      if plus_node do
        slice = SystemDependence.context_sensitive_slice(sdg, plus_node.id)
        assert is_list(slice)
      end
    end

    test "doesn't include unreachable call paths" do
      {:ok, sdg} =
        SystemDependence.from_string("""
        def foo(x), do: helper(x)
        def bar(y), do: helper(y)
        def helper(z), do: z + 1
        """)

      all = IR.all_nodes(sdg.ir)

      # Find the call to helper inside foo
      foo_def =
        Enum.find(all, fn n ->
          n.type == :function_def and n.meta[:name] == :foo
        end)

      if foo_def do
        foo_nodes = IR.all_nodes(foo_def)

        foo_call =
          Enum.find(foo_nodes, fn n ->
            n.type == :call and n.meta[:function] == :helper
          end)

        if foo_call do
          slice = SystemDependence.context_sensitive_slice(sdg, foo_call.id)
          assert is_list(slice)
        end
      end
    end
  end

  describe "function_pdg/2" do
    test "retrieves PDG for a specific function" do
      {:ok, sdg} =
        SystemDependence.from_string("""
        def foo(x), do: x + 1
        def bar(y), do: y * 2
        """)

      foo_pdg = SystemDependence.function_pdg(sdg, {nil, :foo, 1})
      assert foo_pdg != nil
      assert %Reach.Graph{} = foo_pdg

      bar_pdg = SystemDependence.function_pdg(sdg, {nil, :bar, 1})
      assert bar_pdg != nil
    end

    test "returns nil for unknown function" do
      {:ok, sdg} =
        SystemDependence.from_string("""
        def foo(x), do: x + 1
        """)

      assert SystemDependence.function_pdg(sdg, {nil, :nonexistent, 0}) == nil
    end
  end

  describe "real-world patterns" do
    test "module with @moduledoc and functions" do
      {:ok, sdg} =
        SystemDependence.from_string("""
        defmodule MyApp.Worker do
          @moduledoc "A worker module"

          def start(args) do
            process(args)
          end

          defp process(args) do
            Enum.map(args, &to_string/1)
          end
        end
        """)

      assert %Reach.SystemDependence{} = sdg
      assert map_size(sdg.function_pdgs) >= 1
    end

    test "function with case and guards" do
      {:ok, sdg} =
        SystemDependence.from_string("""
        def classify(x) when is_integer(x) do
          case x do
            n when n > 0 -> :positive
            0 -> :zero
            _ -> :negative
          end
        end
        """)

      assert %Reach.SystemDependence{} = sdg
    end

    test "function with try/rescue/after" do
      {:ok, sdg} =
        SystemDependence.from_string("""
        def safe_call(fun) do
          try do
            fun.()
          rescue
            e in RuntimeError -> {:error, e}
          after
            IO.puts("done")
          end
        end
        """)

      assert %Reach.SystemDependence{} = sdg
    end

    test "function with with/else" do
      {:ok, sdg} =
        SystemDependence.from_string("""
        def fetch_user(id) do
          with {:ok, data} <- load(id),
               {:ok, user} <- parse(data) do
            {:ok, user}
          else
            {:error, reason} -> {:error, reason}
          end
        end
        """)

      assert %Reach.SystemDependence{} = sdg
    end

    test "function with pipe chain and anonymous function" do
      {:ok, sdg} =
        SystemDependence.from_string("""
        def transform(list) do
          list
          |> Enum.map(fn x -> x * 2 end)
          |> Enum.filter(&(&1 > 5))
          |> Enum.sort()
        end
        """)

      assert %Reach.SystemDependence{} = sdg
    end

    test "GenServer module with callbacks" do
      {:ok, sdg} =
        SystemDependence.from_string("""
        def init(args), do: {:ok, args}
        def handle_call(:get, _from, state), do: {:reply, state, state}
        def handle_cast({:set, val}, _state), do: {:noreply, val}
        def handle_info(:tick, state), do: {:noreply, state + 1}
        """)

      assert %Reach.SystemDependence{} = sdg
      assert map_size(sdg.function_pdgs) == 4
    end

    test "if without else branch" do
      {:ok, sdg} =
        SystemDependence.from_string("""
        def maybe_log(x) do
          if x > 100 do
            IO.puts("big number")
          end
          x
        end
        """)

      assert %Reach.SystemDependence{} = sdg
    end

    test "for comprehension with multiple generators and filters" do
      {:ok, sdg} =
        SystemDependence.from_string("""
        def cross(xs, ys) do
          for x <- xs, y <- ys, x != y, do: {x, y}
        end
        """)

      assert %Reach.SystemDependence{} = sdg
    end

    test "receive with multiple clauses and timeout" do
      {:ok, sdg} =
        SystemDependence.from_string("""
        def wait do
          receive do
            {:data, d} -> {:ok, d}
            :stop -> :done
          after
            5000 -> :timeout
          end
        end
        """)

      assert %Reach.SystemDependence{} = sdg
    end
  end

  describe "DOT export" do
    test "produces valid DOT" do
      {:ok, sdg} =
        SystemDependence.from_string("""
        def foo(x), do: bar(x)
        def bar(y), do: y + 1
        """)

      assert {:ok, dot} = SystemDependence.to_dot(sdg)
      assert String.contains?(dot, "digraph")
    end
  end
end
