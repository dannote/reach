if Code.ensure_loaded?(QuickBEAM) do
  defmodule Reach.Plugins.QuickBEAMTest do
    use ExUnit.Case, async: true

    alias Reach.Plugins.QuickBEAM, as: Plugin

    describe "cross-language edges" do
      test "eval with string literal creates JS function nodes and :js_eval edges" do
        graph =
          Reach.string_to_graph!(
            ~S"""
            defmodule MyApp do
              def run do
                {:ok, rt} = QuickBEAM.start()
                QuickBEAM.eval(rt, "function add(a, b) { return a + b; }")
                QuickBEAM.stop(rt)
              end
            end
            """,
            plugins: [Plugin]
          )

        all = Reach.nodes(graph)
        js_fns = Enum.filter(all, &(&1.meta[:language] == :javascript))
        assert [%{meta: %{name: :add, arity: 2}}] = js_fns

        g = Reach.to_graph(graph)
        eval_edges = Graph.edges(g) |> Enum.filter(&(&1.label == :js_eval))
        assert length(eval_edges) == 1
      end

      test "eval with variable (not literal) produces no JS nodes" do
        graph =
          Reach.string_to_graph!(
            ~S"""
            defmodule MyApp do
              def run(code) do
                {:ok, rt} = QuickBEAM.start()
                QuickBEAM.eval(rt, code)
                QuickBEAM.stop(rt)
              end
            end
            """,
            plugins: [Plugin]
          )

        js_fns = Reach.nodes(graph) |> Enum.filter(&(&1.meta[:language] == :javascript))
        assert js_fns == []
      end

      test "call links to JS function by name" do
        graph =
          Reach.string_to_graph!(
            ~S"""
            defmodule MyApp do
              def run do
                {:ok, rt} = QuickBEAM.start()
                QuickBEAM.eval(rt, "function greet() { return 'hi'; }")
                QuickBEAM.call(rt, "greet", [])
                QuickBEAM.stop(rt)
              end
            end
            """,
            plugins: [Plugin]
          )

        g = Reach.to_graph(graph)

        call_edges =
          Graph.edges(g)
          |> Enum.filter(&match?({:js_call, _}, &1.label))
          |> Enum.map(& &1.label)

        assert {:js_call, :greet} in call_edges
      end

      test "Beam.call in JS links to Elixir handler" do
        source = ~S|
        defmodule MyApp do
          def run do
            {:ok, rt} = QuickBEAM.start(
              handlers: %{"double" => fn [n] -> n * 2 end}
            )
            QuickBEAM.eval(rt, "async function main() { return await Beam.call(\"double\", 5); }")
            QuickBEAM.stop(rt)
          end
        end
        |

        graph = Reach.string_to_graph!(source, plugins: [Plugin])
        g = Reach.to_graph(graph)

        beam_edges =
          Graph.edges(g)
          |> Enum.filter(&match?({:beam_call, _}, &1.label))
          |> Enum.map(& &1.label)

        assert {:beam_call, "double"} in beam_edges
      end

      test "multiple JS functions from single eval" do
        graph =
          Reach.string_to_graph!(
            ~S"""
            defmodule MyApp do
              def run do
                {:ok, rt} = QuickBEAM.start()
                QuickBEAM.eval(rt, "function a() {} function b() {} function c() {}")
                QuickBEAM.stop(rt)
              end
            end
            """,
            plugins: [Plugin]
          )

        js_fns = Reach.nodes(graph) |> Enum.filter(&(&1.meta[:language] == :javascript))
        names = Enum.map(js_fns, & &1.meta[:name]) |> Enum.sort()
        assert names == [:a, :b, :c]
      end
    end

    describe "effect classification" do
      test "classifies QuickBEAM API calls" do
        for {fun, expected} <- [
              eval: :io,
              call: :io,
              start: :io,
              stop: :io,
              compile: :read,
              set_global: :write
            ] do
          node = %Reach.IR.Node{
            type: :call,
            id: 0,
            children: [],
            meta: %{module: QuickBEAM, function: fun}
          }

          assert Plugin.classify_effect(node) == expected,
                 "expected #{fun} -> #{expected}, got #{Plugin.classify_effect(node)}"
        end
      end

      test "classifies OXC pure vs IO" do
        for {fun, expected} <- [
              parse: :pure,
              postwalk: :pure,
              patch_string: :pure,
              transform: :io,
              bundle: :io
            ] do
          node = %Reach.IR.Node{
            type: :call,
            id: 0,
            children: [],
            meta: %{module: OXC, function: fun}
          }

          assert Plugin.classify_effect(node) == expected,
                 "expected OXC.#{fun} -> #{expected}"
        end
      end

      test "classifies Vize as :io" do
        node = %Reach.IR.Node{
          type: :call,
          id: 0,
          children: [],
          meta: %{module: Vize, function: :compile_sfc}
        }

        assert Plugin.classify_effect(node) == :io
      end

      test "returns nil for unrelated calls" do
        node = %Reach.IR.Node{
          type: :call,
          id: 0,
          children: [],
          meta: %{module: Enum, function: :map}
        }

        assert Plugin.classify_effect(node) == nil
      end
    end
  end
end
