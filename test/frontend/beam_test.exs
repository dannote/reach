defmodule ExPDG.Frontend.BEAMTest do
  use ExUnit.Case, async: false

  describe "compiled_to_graph/2" do
    test "captures macro-injected callbacks from use GenServer" do
      mod = :"ExPDGTestGS#{System.unique_integer([:positive])}"

      source = "defmodule #{mod} do
  use GenServer

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call(:get, _from, state), do: {:reply, state, state}
end"

      {:ok, graph} = ExPDG.compiled_to_graph(source)
      funcs = ExPDG.nodes(graph, type: :function_def)
      func_names = Enum.map(funcs, & &1.meta[:name]) |> Enum.uniq()

      assert :init in func_names
      assert :handle_call in func_names
      assert :child_spec in func_names, "use GenServer should inject child_spec"
    end

    test "captures try/rescue inside macros" do
      mod = :"ExPDGTestTR#{System.unique_integer([:positive])}"

      source = "defmodule #{mod} do
  defmacrop safe(do: body) do
    quote do
      try do
        unquote(body)
      rescue
        e -> {:error, e}
      end
    end
  end

  def run(x) do
    safe do
      x + 1
    end
  end
end"

      {:ok, graph} = ExPDG.compiled_to_graph(source)
      all = ExPDG.nodes(graph)

      func_names =
        all
        |> Enum.filter(&(&1.type == :function_def))
        |> Enum.map(& &1.meta[:name])

      assert :run in func_names

      types = Enum.map(all, & &1.type) |> Enum.uniq()

      assert :try in types or :catch_clause in types,
             "expanded code should contain try/catch, got types: #{inspect(types)}"
    end
  end

  describe "module_to_graph/2" do
    test "analyzes a loaded module" do
      {:ok, graph} = ExPDG.module_to_graph(Enum)
      funcs = ExPDG.nodes(graph, type: :function_def)
      func_names = Enum.map(funcs, & &1.meta[:name]) |> Enum.uniq()

      assert :map in func_names
      assert :filter in func_names
      assert :reduce in func_names
    end

    test "returns error for non-existing module" do
      assert {:error, :module_not_found} = ExPDG.module_to_graph(NonExistentModule12345)
    end
  end
end
