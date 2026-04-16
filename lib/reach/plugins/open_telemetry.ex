defmodule Reach.Plugins.OpenTelemetry do
  @moduledoc false
  @behaviour Reach.Plugin

  alias Reach.IR

  import Reach.Plugins.Helpers, only: [find_vars_in: 1]

  @tracer_modules [OpenTelemetry.Tracer, :otel_tracer, nil]

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

  # with_span/start_span → body content (control scope)
  defp span_scope_edges(all_nodes) do
    span_calls =
      Enum.filter(all_nodes, fn n ->
        n.type == :call and
          n.meta[:module] in @tracer_modules and
          n.meta[:function] in [:with_span, :start_span]
      end)

    func_defs =
      Enum.filter(all_nodes, &(&1.type == :function_def))

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

  # set_attribute/add_event — data flowing into span telemetry
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

  # Ctx.get_current → Ctx.attach (cross-process trace propagation)
  defp context_propagation_edges(all_nodes) do
    ctx_gets =
      Enum.filter(all_nodes, fn n ->
        n.type == :call and
          ctx_module?(n.meta[:module]) and
          n.meta[:function] in [:get_current, :get_value]
      end)

    ctx_attaches =
      Enum.filter(all_nodes, fn n ->
        n.type == :call and
          ctx_module?(n.meta[:module]) and
          n.meta[:function] in [:attach, :set_value]
      end)

    for get <- ctx_gets,
        attach <- ctx_attaches do
      {get.id, attach.id, :otel_context_propagation}
    end
  end

  # :telemetry.execute → :telemetry.attach within the same module
  defp telemetry_event_edges(all_nodes) do
    executes =
      Enum.filter(all_nodes, &telemetry_call?(&1, :execute))

    attaches =
      Enum.filter(all_nodes, fn n ->
        telemetry_call?(n, :attach) or telemetry_call?(n, :attach_many)
      end)

    for exec <- executes, attach <- attaches do
      {exec.id, attach.id, :otel_telemetry_event}
    end
  end

  # Cross-module: :telemetry.execute in module A → :telemetry.attach in module B
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

    for exec <- executes,
        attach <- attaches do
      {exec.id, attach.id, :otel_telemetry_route}
    end
  end

  defp telemetry_call?(node, function) do
    node.meta[:function] == function and
      node.meta[:module] in [:telemetry, nil]
  end

  @ctx_modules [OpenTelemetry.Ctx, :otel_ctx, OpenTelemetry.Ctx.TokenStorage]

  defp ctx_module?(mod) when is_atom(mod), do: mod in @ctx_modules
  defp ctx_module?(_), do: false

  defp extract_span_name(span_call) do
    span_call.children
    |> Enum.find_value(fn n ->
      if n.type == :literal, do: n.meta[:value]
    end)
  end

  defp find_enclosing_function(func_defs, node) do
    Enum.find(func_defs, fn func ->
      func
      |> IR.all_nodes()
      |> Enum.any?(&(&1.id == node.id))
    end)
  end
end
