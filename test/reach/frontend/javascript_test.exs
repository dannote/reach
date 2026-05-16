if Code.ensure_loaded?(QuickBEAM) do
  defmodule Reach.Plugins.QuickBEAM.JavaScriptFrontendTest do
    use ExUnit.Case, async: true

    alias Reach.Plugins.QuickBEAM.JavaScriptFrontend

    describe "parse/2" do
      test "translates simple function" do
        {:ok, [node]} =
          JavaScriptFrontend.parse("function add(a, b) { return a + b; }")

        assert node.type == :function_def
        assert node.meta[:name] == :add
        assert node.meta[:arity] == 2
        assert node.meta[:language] == :javascript

        all = Reach.IR.all_nodes(node)
        vars = Enum.filter(all, &(&1.type == :var))
        var_names = Enum.map(vars, & &1.meta[:name]) |> Enum.uniq()
        assert :a in var_names
        assert :b in var_names

        ops = Enum.filter(all, &(&1.type == :binary_op))
        assert Enum.any?(ops, &(&1.meta[:operator] == :+))
      end

      test "translates multiple functions" do
        {:ok, nodes} =
          JavaScriptFrontend.parse("""
          function foo() { return 1; }
          function bar(x) { return x; }
          """)

        names = Enum.map(nodes, & &1.meta[:name])
        assert :foo in names
        assert :bar in names
      end

      test "translates local variable assignments" do
        {:ok, [node]} =
          JavaScriptFrontend.parse("function f(x) { let y = x + 1; return y; }")

        all = Reach.IR.all_nodes(node)
        matches = Enum.filter(all, &(&1.type == :match))
        assert matches != []

        defs = Enum.filter(all, &(&1.type == :var and &1.meta[:binding_role] == :definition))
        def_names = Enum.map(defs, & &1.meta[:name])
        assert :y in def_names
      end

      test "translates nested functions" do
        {:ok, nodes} =
          JavaScriptFrontend.parse("""
          function outer(x) {
            return {
              inner: function() { return x; }
            };
          }
          """)

        all = nodes |> Enum.flat_map(&Reach.IR.all_nodes/1)
        fn_defs = Enum.filter(all, &(&1.type == :function_def))
        assert length(fn_defs) >= 2
      end

      test "returns error for invalid syntax" do
        assert {:error, _} = JavaScriptFrontend.parse("function {{{")
      end
    end

    describe "parse_file/2" do
      test "reads and parses a JS file" do
        path = Path.join(System.tmp_dir!(), "reach_js_test.js")
        File.write!(path, "function hello(name) { return name; }")

        {:ok, [node]} = JavaScriptFrontend.parse_file(path)
        assert node.meta[:name] == :hello
        assert node.meta[:arity] == 1
      after
        File.rm(Path.join(System.tmp_dir!(), "reach_js_test.js"))
      end

      test "returns error for missing file" do
        assert {:error, {:file, :enoent}} = JavaScriptFrontend.parse_file("/nonexistent.js")
      end
    end

    describe "method calls" do
      test "translates obj.method(args) correctly" do
        {:ok, [node]} =
          JavaScriptFrontend.parse("function f() { return console.log('hello'); }")

        all = Reach.IR.all_nodes(node)
        calls = Enum.filter(all, &(&1.type == :call and &1.meta[:kind] == :remote))
        assert [%{meta: %{module: :console, function: :log}}] = calls
      end

      test "translates Beam.callSync with correct args" do
        {:ok, [node]} =
          JavaScriptFrontend.parse("""
          function main() {
            const x = Beam.callSync("handler", 42);
            return x;
          }
          """)

        all = Reach.IR.all_nodes(node)

        beam_calls =
          Enum.filter(all, fn n ->
            n.type == :call and n.meta[:module] == :Beam and n.meta[:function] == :callSync
          end)

        assert [call] = beam_calls
        assert call.meta[:arity] == 2

        [name_arg, val_arg] = call.children
        assert name_arg.meta[:value] == "handler"
        assert val_arg.meta[:value] == 42
      end
    end

    describe "global variables" do
      test "get_var produces variable reference" do
        {:ok, [node]} =
          JavaScriptFrontend.parse("function f() { return globalThis; }")

        all = Reach.IR.all_nodes(node)
        vars = Enum.filter(all, &(&1.type == :var and &1.meta[:name] == :globalThis))
        assert vars != []
      end
    end
  end
end
