defmodule Reach.Plugins.OpenTelemetry do
  @moduledoc "Plugin for OpenTelemetry span and context propagation."
  @behaviour Reach.Plugin

  alias Reach.IR
  alias Reach.IR.Node

  import Reach.Plugins.Helpers, only: [find_vars_in: 1]

  @tracer_modules [OpenTelemetry.Tracer, :otel_tracer]
  @ctx_modules [OpenTelemetry.Ctx, :otel_ctx]

  @impl true
  def classify_effect(%Node{type: :call, meta: %{module: mod, function: fun}})
      when mod in [OpenTelemetry.Tracer, :otel_tracer] and
             fun in [:with_span, :start_span, :end_span, :set_current_span],
      do: :io

  def classify_effect(%Node{type: :call, meta: %{module: mod, function: fun}})
      when mod in [OpenTelemetry.Tracer, :otel_tracer] and
             fun in [
               :set_attribute,
               :set_attributes,
               :add_event,
               :add_events,
               :set_status,
               :record_exception,
               :update_name
             ],
      do: :io

  def classify_effect(%Node{type: :call, meta: %{module: mod, function: fun}})
      when mod in [OpenTelemetry.Tracer, :otel_tracer] and
             fun in [:current_span_ctx, :non_recording_span, :from_remote_span],
      do: :read

  def classify_effect(%Node{type: :call, meta: %{module: mod, function: fun}})
      when mod in [OpenTelemetry.Span, :otel_span] and
             fun in [:record_exception],
      do: :io

  # otel_ctx — process dictionary based context
  def classify_effect(%Node{type: :call, meta: %{module: mod, function: fun}})
      when mod in [OpenTelemetry.Ctx, :otel_ctx] and
             fun in [:set_value, :attach, :detach, :clear, :remove],
      do: :write

  def classify_effect(%Node{type: :call, meta: %{module: mod, function: fun}})
      when mod in [OpenTelemetry.Ctx, :otel_ctx] and
             fun in [:get_value, :get_current, :new],
      do: :read

  # Baggage — pure query, stored in context
  def classify_effect(%Node{type: :call, meta: %{module: mod, function: fun}})
      when mod in [OpenTelemetry.Baggage, :otel_baggage] and
             fun in [:set, :clear, :remove],
      do: :write

  def classify_effect(%Node{type: :call, meta: %{module: mod, function: fun}})
      when mod in [OpenTelemetry.Baggage, :otel_baggage] and
             fun in [:get_all, :get_text_map_propagators],
      do: :read

  # :telemetry — Erlang telemetry library
  def classify_effect(%Node{type: :call, meta: %{module: :telemetry, function: :execute}}),
    do: :io

  def classify_effect(%Node{type: :call, meta: %{module: :telemetry, function: :span}}),
    do: :io

  def classify_effect(%Node{type: :call, meta: %{module: :telemetry, function: fun}})
      when fun in [:attach, :attach_many, :detach],
      do: :io

  def classify_effect(%Node{type: :call, meta: %{module: :telemetry, function: fun}})
      when fun in [:list_handlers],
      do: :read

  def classify_effect(_), do: nil

  @impl true
  def analyze(all_nodes, _opts) do
    span_scope_edges(all_nodes) ++
      span_attribute_edges(all_nodes) ++
      context_propagation_edges(all_nodes) ++
      telemetry_event_edges(all_nodes)
  end

  @impl true
  def analyze_project(_modules, all_nodes, _opts) do
    cross_module_telemetry_edges(all_nodes)
  end

  defp span_scope_edges(all_nodes) do
    span_calls =
      Enum.filter(all_nodes, fn n ->
        n.type == :call and
          n.meta[:module] in @tracer_modules and
          n.meta[:function] in [:with_span, :start_span]
      end)

    func_defs = Enum.filter(all_nodes, &(&1.type == :function_def))

    Enum.flat_map(span_calls, &span_body_edges(&1, func_defs))
  end

  defp span_body_edges(span, func_defs) do
    case find_enclosing_function(func_defs, span) do
      nil ->
        []

      func ->
        span_name = extract_span_name(span)

        func
        |> IR.all_nodes()
        |> Enum.filter(&(&1.type == :call and &1.id != span.id))
        |> Enum.map(fn call -> {span.id, call.id, {:otel_span_scope, span_name}} end)
    end
  end

  defp span_attribute_edges(all_nodes) do
    attr_calls =
      Enum.filter(all_nodes, fn n ->
        n.type == :call and
          n.meta[:module] in @tracer_modules and
          n.meta[:function] in [:set_attribute, :set_attributes, :add_event]
      end)

    for call <- attr_calls,
        arg <- call.children,
        var <- find_vars_in(arg) do
      {var.id, call.id, {:otel_span_data, call.meta[:function]}}
    end
  end

  defp context_propagation_edges(all_nodes) do
    ctx_gets =
      Enum.filter(all_nodes, fn n ->
        n.type == :call and
          n.meta[:module] in @ctx_modules and
          n.meta[:function] in [:get_value, :get_current, :new]
      end)

    ctx_sets =
      Enum.filter(all_nodes, fn n ->
        n.type == :call and
          n.meta[:module] in @ctx_modules and
          n.meta[:function] in [:set_value, :attach, :detach, :clear, :remove]
      end)

    for get <- ctx_gets, set <- ctx_sets do
      {get.id, set.id, :otel_context_propagation}
    end
  end

  defp telemetry_event_edges(all_nodes) do
    executes = Enum.filter(all_nodes, &telemetry_call?(&1, :execute))

    attaches =
      Enum.filter(all_nodes, fn n ->
        telemetry_call?(n, :attach) or telemetry_call?(n, :attach_many)
      end)

    for exec <- executes, attach <- attaches do
      {exec.id, attach.id, :otel_telemetry_event}
    end
  end

  defp cross_module_telemetry_edges(all_nodes) do
    executes =
      Enum.filter(all_nodes, fn n ->
        n.type == :call and telemetry_call?(n, :execute)
      end)

    attaches =
      Enum.filter(all_nodes, fn n ->
        n.type == :call and
          (telemetry_call?(n, :attach) or telemetry_call?(n, :attach_many))
      end)

    for exec <- executes, attach <- attaches do
      {exec.id, attach.id, :otel_telemetry_route}
    end
  end

  defp telemetry_call?(node, function) do
    node.meta[:function] == function and node.meta[:module] == :telemetry
  end

  defp extract_span_name(span_call) do
    span_call.children
    |> Enum.find_value(fn n ->
      if n.type == :literal, do: n.meta[:value]
    end)
  end

  defp find_enclosing_function(func_defs, node) do
    Enum.find(func_defs, fn func ->
      func |> IR.all_nodes() |> Enum.any?(&(&1.id == node.id))
    end)
  end
end
