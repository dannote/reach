defmodule Reach.ConcurrencyTest do
  use ExUnit.Case, async: true

  alias Reach.Concurrency
  alias Reach.IR

  defp analyze(source) do
    {:ok, nodes} = IR.from_string(source)
    all_nodes = IR.all_nodes(nodes)
    {nodes, Concurrency.analyze(nodes, all_nodes: all_nodes)}
  end

  defp edge_labels(graph) do
    graph |> Graph.edges() |> Enum.map(& &1.label)
  end

  describe "Process.monitor → :DOWN handler" do
    test "creates monitor_down edge" do
      {_, graph} =
        analyze("""
        defmodule MyServer do
          def start_monitoring(pid) do
            Process.monitor(pid)
          end

          def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
            {:noreply, state}
          end
        end
        """)

      assert :monitor_down in edge_labels(graph)
    end

    test "no edge when no :DOWN handler exists" do
      {_, graph} =
        analyze("""
        defmodule MyServer do
          def start_monitoring(pid) do
            Process.monitor(pid)
          end

          def handle_info(:other, state) do
            {:noreply, state}
          end
        end
        """)

      refute :monitor_down in edge_labels(graph)
    end
  end

  describe "Process.flag(:trap_exit) → :EXIT handler" do
    test "creates trap_exit edge" do
      {_, graph} =
        analyze("""
        defmodule MyServer do
          def init(state) do
            Process.flag(:trap_exit, true)
            {:ok, state}
          end

          def handle_info({:EXIT, _pid, _reason}, state) do
            {:noreply, state}
          end
        end
        """)

      assert :trap_exit in edge_labels(graph)
    end

    test "no edge when not trapping exits" do
      {_, graph} =
        analyze("""
        defmodule MyServer do
          def init(state) do
            {:ok, state}
          end

          def handle_info({:EXIT, _pid, _reason}, state) do
            {:noreply, state}
          end
        end
        """)

      refute :trap_exit in edge_labels(graph)
    end
  end

  describe "spawn_link → exit flow" do
    test "creates link_exit edge for spawn_link" do
      {_, graph} =
        analyze("""
        defmodule MyServer do
          def start_worker do
            spawn_link(fn -> work() end)
          end

          def handle_info(msg, state) do
            {:noreply, state}
          end
        end
        """)

      assert :link_exit in edge_labels(graph)
    end

    test "creates link_exit edge for Process.link" do
      {_, graph} =
        analyze("""
        defmodule MyServer do
          def link_to(pid) do
            Process.link(pid)
          end

          def handle_info(msg, state) do
            {:noreply, state}
          end
        end
        """)

      assert :link_exit in edge_labels(graph)
    end
  end

  describe "Task.async → Task.await" do
    test "creates task_result edge" do
      {_, graph} =
        analyze("""
        def compute(data) do
          task = Task.async(fn -> process(data) end)
          Task.await(task)
        end
        """)

      assert :task_result in edge_labels(graph)
    end

    test "works with Task.async_stream and Task.yield" do
      {_, graph} =
        analyze("""
        def batch(items) do
          tasks = Task.async_stream(items, &process/1)
          Task.yield_many(tasks)
        end
        """)

      labels = edge_labels(graph)
      assert :task_result in labels
    end

    test "no edge when only async without await" do
      {_, graph} =
        analyze("""
        def fire_and_forget(data) do
          Task.async(fn -> process(data) end)
        end
        """)

      refute :task_result in edge_labels(graph)
    end
  end

  describe "integration with SDG" do
    test "concurrency edges appear in full graph" do
      graph =
        Reach.string_to_graph!("""
        defmodule MyWorker do
          def run do
            task = Task.async(fn -> compute() end)
            result = Task.await(task)
            result
          end
        end
        """)

      edges = Reach.edges(graph)
      labels = Enum.map(edges, & &1.label)
      assert :task_result in labels
    end

    test "monitor edges in GenServer-like module" do
      graph =
        Reach.string_to_graph!("""
        defmodule Watcher do
          def watch(pid) do
            Process.monitor(pid)
          end

          def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
            {:noreply, Map.delete(state, pid)}
          end
        end
        """)

      edges = Reach.edges(graph)
      labels = Enum.map(edges, & &1.label)
      assert :monitor_down in labels
    end
  end
end
