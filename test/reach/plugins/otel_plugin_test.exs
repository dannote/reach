defmodule Reach.Plugins.OpenTelemetryTest do
  use ExUnit.Case, async: true

  @tmp_dir Path.join(System.tmp_dir!(), "reach_otel_test")

  setup do
    File.rm_rf!(@tmp_dir)
    File.mkdir_p!(@tmp_dir)
    on_exit(fn -> File.rm_rf!(@tmp_dir) end)
    :ok
  end

  describe "span scope edges" do
    test "with_span call controls body calls" do
      graph =
        Reach.string_to_graph!(
          """
          defmodule MyService do
            def process(input) do
              OpenTelemetry.Tracer.with_span("process") do
                result = do_work(input)
                store(result)
              end
            end
          end
          """,
          plugins: [Reach.Plugins.OpenTelemetry]
        )

      edges = Reach.edges(graph)

      span_edges =
        Enum.filter(edges, fn e ->
          match?({:otel_span_scope, _}, e.label)
        end)

      assert span_edges != []

      span_call =
        Reach.nodes(graph)
        |> Enum.find(&(&1.meta[:function] == :with_span))

      assert Enum.all?(span_edges, &(&1.v1 == span_call.id))

      {_, name} = hd(span_edges).label
      assert name == "process"
    end
  end

  describe "span attribute edges" do
    test "vars flow into set_attribute" do
      graph =
        Reach.string_to_graph!(
          """
          defmodule MyService do
            def handle(user_id) do
              OpenTelemetry.Tracer.set_attribute(:user_id, user_id)
            end
          end
          """,
          plugins: [Reach.Plugins.OpenTelemetry]
        )

      edges = Reach.edges(graph)

      attr_edges =
        Enum.filter(edges, fn e ->
          match?({:otel_span_data, _}, e.label)
        end)

      assert attr_edges != []

      set_call =
        Reach.nodes(graph)
        |> Enum.find(&(&1.meta[:function] == :set_attribute))

      assert Enum.all?(attr_edges, &(&1.v2 == set_call.id))
    end
  end

  describe "context propagation edges" do
    test "Ctx.get_current → Ctx.attach" do
      graph =
        Reach.string_to_graph!(
          """
          defmodule MyWorker do
            def spawn_traced(work) do
              ctx = OpenTelemetry.Ctx.get_current()

              Task.async(fn ->
                OpenTelemetry.Ctx.attach(ctx)
                work.()
              end)
            end
          end
          """,
          plugins: [Reach.Plugins.OpenTelemetry]
        )

      edges = Reach.edges(graph)
      prop_edges = Enum.filter(edges, &(&1.label == :otel_context_propagation))
      assert prop_edges != []

      get_call =
        Reach.nodes(graph)
        |> Enum.find(&(&1.meta[:function] == :get_current))

      attach_call =
        Reach.nodes(graph)
        |> Enum.find(&(&1.meta[:function] == :attach))

      [edge] = prop_edges
      assert edge.v1 == get_call.id
      assert edge.v2 == attach_call.id
    end
  end

  describe "telemetry event edges" do
    test ":telemetry.execute → :telemetry.attach in same function" do
      graph =
        Reach.string_to_graph!(
          """
          defmodule MyApp do
            def setup do
              :telemetry.attach("handler", [:my, :event], &handle/4, %{})
              :telemetry.execute([:my, :event], %{count: 1})
            end
          end
          """,
          plugins: [Reach.Plugins.OpenTelemetry]
        )

      edges = Reach.edges(graph)
      tel_edges = Enum.filter(edges, &(&1.label == :otel_telemetry_event))
      assert tel_edges != []
    end
  end

  describe "cross-module telemetry" do
    test "execute in module A → attach in module B" do
      File.write!(Path.join(@tmp_dir, "emitter.ex"), """
      defmodule OtelTestEmitter do
        def emit do
          :telemetry.execute([:my, :event], %{val: 1})
        end
      end
      """)

      File.write!(Path.join(@tmp_dir, "handler.ex"), """
      defmodule OtelTestHandler do
        def setup do
          :telemetry.attach("handler", [:my, :event], &handle/4, nil)
        end
      end
      """)

      paths = Path.wildcard(Path.join(@tmp_dir, "*.ex"))

      project =
        Reach.Project.from_sources(paths, plugins: [Reach.Plugins.OpenTelemetry])

      edges = Graph.edges(project.graph)
      route_edges = Enum.filter(edges, &(&1.label == :otel_telemetry_route))
      assert route_edges != []
    end
  end
end
