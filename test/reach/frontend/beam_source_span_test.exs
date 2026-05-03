defmodule Reach.Frontend.BEAM.SourceSpanTest do
  use ExUnit.Case, async: false

  describe "source_span normalization" do
    test "start_line is always integer or nil for Elixir stdlib modules" do
      for mod <- [Enum, Map, String, Keyword, GenServer] do
        {:ok, g} = Reach.module_to_graph(mod)

        for node <- Reach.nodes(g), span = node.source_span, span != nil do
          assert is_integer(span.start_line) or is_nil(span.start_line),
                 "#{inspect(mod)}: expected integer or nil start_line, got #{inspect(span.start_line)}"
        end
      end
    end

    test "start_line is always integer or nil for OTP modules" do
      for mod <- [:gen_server, :supervisor, :ets, :lists, :maps] do
        {:ok, g} = Reach.module_to_graph(mod)

        for node <- Reach.nodes(g), span = node.source_span, span != nil do
          assert is_integer(span.start_line) or is_nil(span.start_line),
                 "#{inspect(mod)}: expected integer or nil start_line, got #{inspect(span.start_line)}"
        end
      end
    end

    test "start_col extracts column from {line, col} annotations" do
      {:ok, g} = Reach.module_to_graph(Enum)

      nodes_with_col =
        g
        |> Reach.nodes()
        |> Enum.count(fn n ->
          case n.source_span do
            %{start_col: c} when is_integer(c) and c > 1 -> true
            _ -> false
          end
        end)

      assert nodes_with_col > 0,
             "expected some nodes with column > 1 from {line, col} annotations"
    end

    test "start_col is always integer or nil" do
      {:ok, g} = Reach.module_to_graph(Enum)

      for node <- Reach.nodes(g), span = node.source_span, span != nil do
        assert is_integer(span.start_col) or is_nil(span.start_col),
               "expected integer or nil start_col, got #{inspect(span.start_col)}"
      end
    end

    test "no tuple or keyword list shapes remain in start_line" do
      {:ok, g} = Reach.module_to_graph(Macro)

      shapes =
        g
        |> Reach.nodes()
        |> Enum.map(& &1.source_span)
        |> Enum.reject(&is_nil/1)
        |> Enum.map(& &1.start_line)
        |> Enum.reject(&is_nil/1)

      tuples = Enum.count(shapes, &is_tuple/1)
      keywords = Enum.count(shapes, &is_list/1)

      assert tuples == 0, "found #{tuples} tuple start_line values"
      assert keywords == 0, "found #{keywords} keyword list start_line values"
    end

    test "compiled_to_graph also produces normalized spans" do
      source = """
      defmodule ReachSpanTest#{System.unique_integer([:positive])} do
        def foo(x), do: x + 1
        def bar(y) when is_integer(y), do: y * 2
      end
      """

      {:ok, graph} = Reach.compiled_to_graph(source)

      for node <- Reach.nodes(graph), span = node.source_span, span != nil do
        assert is_integer(span.start_line) or is_nil(span.start_line),
               "compiled_to_graph: expected integer or nil, got #{inspect(span.start_line)}"
      end
    end
  end

  describe "visualization of BEAM modules" do
    test "to_json succeeds for Elixir stdlib modules" do
      for mod <- [Access, Enum, Map] do
        {:ok, g} = Reach.module_to_graph(mod)
        json = Reach.Visualize.to_json(g)
        parsed = Jason.decode!(json)
        funcs = Enum.flat_map(parsed["control_flow"], & &1["functions"])

        assert funcs != [],
               "#{inspect(mod)}: expected functions in visualization"
      end
    end

    test "to_json succeeds for OTP modules" do
      for mod <- [:gen_server, :ets, :lists] do
        {:ok, g} = Reach.module_to_graph(mod)
        json = Reach.Visualize.to_json(g)
        parsed = Jason.decode!(json)
        funcs = Enum.flat_map(parsed["control_flow"], & &1["functions"])

        assert funcs != [],
               "#{inspect(mod)}: expected functions in visualization"
      end
    end
  end
end
