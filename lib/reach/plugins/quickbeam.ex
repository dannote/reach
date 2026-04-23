if Code.ensure_loaded?(QuickBEAM) do
  defmodule Reach.Plugins.QuickBEAM do
    @moduledoc """
    Plugin for cross-language analysis of QuickBEAM (Elixir + JavaScript).

    Detects `QuickBEAM.eval/2,3` and `QuickBEAM.call/3,4` calls where the
    JS source is a string literal, parses the embedded JavaScript, and
    connects the two graphs with cross-language edges:

    - `:js_eval` — Elixir eval call → JS function definitions
    - `:js_call` — Elixir call site → JS named function
    - `:beam_call` — JS `Beam.call("handler")` → Elixir handler
    """
    @behaviour Reach.Plugin

    alias Reach.{Frontend, IR}
    alias Reach.IR.Node

    @impl true
    def analyze(_all_nodes, _opts), do: []

    @impl true
    def classify_effect(%Node{type: :call, meta: %{module: QuickBEAM, function: f}})
        when f in [:eval, :call, :load_module, :load_bytecode, :send_message],
        do: :io

    def classify_effect(%Node{type: :call, meta: %{module: QuickBEAM, function: f}})
        when f in [:start, :stop, :reset],
        do: :io

    def classify_effect(%Node{type: :call, meta: %{module: QuickBEAM, function: f}})
        when f in [:compile, :disasm, :globals, :get_global, :info, :memory_usage, :coverage],
        do: :read

    def classify_effect(%Node{type: :call, meta: %{module: QuickBEAM, function: :set_global}}),
      do: :write

    def classify_effect(_), do: nil

    @impl true
    def analyze_embedded(all_nodes, opts) do
      counter = Keyword.get(opts, :counter, IR.Counter.new())

      {js_nodes, eval_edges} =
        all_nodes
        |> find_eval_calls()
        |> Enum.flat_map(&process_eval_call(&1, all_nodes, counter))
        |> Enum.reduce({[], []}, fn {nodes, edges}, {n_acc, e_acc} ->
          {n_acc ++ nodes, e_acc ++ edges}
        end)

      all_js_fns = Enum.filter(js_nodes, &(&1.type == :function_def))

      call_edges =
        all_nodes
        |> find_call_calls()
        |> Enum.flat_map(&link_call_to_js_fn(&1, all_js_fns))

      {js_nodes, eval_edges ++ call_edges}
    end

    defp find_eval_calls(all_nodes) do
      Enum.filter(all_nodes, fn node ->
        node.type == :call and
          node.meta[:module] == QuickBEAM and
          node.meta[:function] == :eval
      end)
    end

    defp find_call_calls(all_nodes) do
      Enum.filter(all_nodes, fn node ->
        node.type == :call and
          node.meta[:module] == QuickBEAM and
          node.meta[:function] == :call
      end)
    end

    defp process_eval_call(call_node, _all_nodes, counter) do
      process_eval(call_node, counter)
    end

    defp link_call_to_js_fn(call_node, js_fns) do
      case extract_fn_name(call_node) do
        nil ->
          []

        fn_name ->
          case Enum.find(js_fns, &(&1.meta[:name] == fn_name)) do
            nil -> []
            target -> [{call_node.id, target.id, {:js_call, fn_name}}]
          end
      end
    end

    defp process_eval(call_node, _counter) do
      with js_source when is_binary(js_source) <- extract_js_source(call_node),
           {:ok, js_nodes} <- Frontend.JavaScript.parse(js_source) do
        edges = Enum.map(js_nodes, fn js_fn -> {call_node.id, js_fn.id, :js_eval} end)
        [{js_nodes, edges}]
      else
        _ -> []
      end
    end

    defp extract_js_source(call_node) do
      case call_node.children do
        [_rt, %Node{type: :literal, meta: %{value: source}} | _] when is_binary(source) ->
          source

        _ ->
          nil
      end
    end

    defp extract_fn_name(call_node) do
      case call_node.children do
        [_rt, %Node{type: :literal, meta: %{value: name}} | _] when is_binary(name) ->
          String.to_atom(name)

        _ ->
          nil
      end
    end
  end
end
