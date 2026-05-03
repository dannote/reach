defmodule Reach.Plugins.JidoTest do
  use ExUnit.Case, async: true

  @tmp_dir Path.join(System.tmp_dir!(), "reach_jido_test")

  setup do
    File.rm_rf!(@tmp_dir)
    File.mkdir_p!(@tmp_dir)
    on_exit(fn -> File.rm_rf!(@tmp_dir) end)
    :ok
  end

  describe "action run/2 edges" do
    test "params flow into run/2 body calls" do
      graph =
        Reach.string_to_graph!(
          """
          defmodule MyAction do
            def run(params, _context) do
              process(params)
              {:ok, %{result: true}}
            end
          end
          """,
          plugins: [Reach.Plugins.Jido]
        )

      edges = Reach.edges(graph)

      action_edges =
        Enum.filter(edges, fn e ->
          match?({:jido_action_params, _}, e.label)
        end)

      assert action_edges != []

      params_def =
        Reach.nodes(graph)
        |> Enum.find(&(&1.meta[:name] == :params and &1.meta[:binding_role] == :definition))

      assert Enum.all?(action_edges, &(&1.v1 == params_def.id))
    end
  end

  describe "signal dispatch edges" do
    test "vars flowing into Dispatch.dispatch" do
      graph =
        Reach.string_to_graph!(
          """
          defmodule MyHandler do
            def handle(signal) do
              Jido.Signal.Dispatch.dispatch(signal, config)
            end
          end
          """,
          plugins: [Reach.Plugins.Jido]
        )

      edges = Reach.edges(graph)
      dispatch_edges = Enum.filter(edges, &(&1.label == :jido_signal_dispatch))
      assert dispatch_edges != []

      dispatch_call =
        Reach.nodes(graph)
        |> Enum.find(&(&1.meta[:function] == :dispatch))

      assert Enum.all?(dispatch_edges, &(&1.v2 == dispatch_call.id))
    end
  end

  describe "tool execute edges" do
    test "params flow into Turn.execute" do
      graph =
        Reach.string_to_graph!(
          """
          defmodule MyStrategy do
            def step(turn, context) do
              Jido.AI.Turn.execute("tool_name", turn.params, context)
            end
          end
          """,
          plugins: [Reach.Plugins.Jido]
        )

      edges = Reach.edges(graph)
      tool_edges = Enum.filter(edges, &(&1.label == :jido_tool_execute))
      assert tool_edges != []

      exec_call =
        Reach.nodes(graph)
        |> Enum.find(&(&1.meta[:function] == :execute))

      assert Enum.all?(tool_edges, &(&1.v2 == exec_call.id))
    end
  end

  describe "memory edges" do
    test "data flowing into remember" do
      graph =
        Reach.string_to_graph!(
          """
          defmodule MyAgent do
            def store(data) do
              remember(data)
            end
          end
          """,
          plugins: [Reach.Plugins.Jido]
        )

      edges = Reach.edges(graph)
      write_edges = Enum.filter(edges, &(&1.label == :jido_memory_write))
      assert write_edges != []

      remember_call =
        Reach.nodes(graph)
        |> Enum.find(&(&1.meta[:function] == :remember))

      assert Enum.all?(write_edges, &(&1.v2 == remember_call.id))
    end
  end

  describe "cross-module" do
    test "signal dispatch → handler in project mode" do
      File.write!(Path.join(@tmp_dir, "dispatcher.ex"), """
      defmodule JidoTestDispatcher do
        def emit(signal) do
          Jido.Signal.Dispatch.dispatch(signal, [])
        end
      end
      """)

      File.write!(Path.join(@tmp_dir, "handler.ex"), """
      defmodule JidoTestHandler do
        def handle_signal(signal, state) do
          process(signal)
          {:ok, state}
        end
      end
      """)

      paths = Path.wildcard(Path.join(@tmp_dir, "*.ex"))
      project = Reach.Project.from_sources(paths, plugins: [Reach.Plugins.Jido])

      edges = Graph.edges(project.graph)
      route_edges = Enum.filter(edges, &(&1.label == :jido_signal_route))
      assert route_edges != []
    end
  end
end
