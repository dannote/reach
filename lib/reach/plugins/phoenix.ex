defmodule Reach.Plugins.Phoenix do
  @moduledoc "Plugin for Phoenix conn, LiveView, and channel semantics."
  @behaviour Reach.Plugin

  alias Reach.IR
  alias Reach.IR.Node

  import Reach.Plugins.Helpers, only: [find_vars_in: 1]

  @assign_modules [nil, Phoenix.Component, Phoenix.LiveView]

  @pure_local [
    :assign,
    :assign_new,
    :push_event,
    :push_patch,
    :push_navigate,
    :put_flash,
    :redirect,
    :render,
    :json,
    :text,
    :html,
    :send_resp,
    :put_status,
    :put_resp_content_type,
    :put_resp_header,
    :halt,
    :put_layout,
    :put_root_layout,
    :put_view,
    :put_new_layout,
    :live_render,
    :live_component,
    :on_mount,
    :embed_templates,
    :attr,
    :slot,
    :sigil_H,
    :sigil_p,
    :plug,
    :get,
    :post,
    :put,
    :delete,
    :patch,
    :pipe_through,
    :scope,
    :live,
    :resources,
    :forward
  ]

  @pure_remote_modules [Phoenix.Component, Phoenix.LiveView, Phoenix.Controller, Plug.Conn]

  @impl true
  def classify_effect(%Node{type: :call, meta: %{kind: :local, function: fun}})
      when fun in @pure_local,
      do: :pure

  def classify_effect(%Node{type: :call, meta: %{kind: :remote, module: mod}})
      when mod in @pure_remote_modules,
      do: :pure

  def classify_effect(%Node{type: :call, meta: %{kind: :remote, module: mod}})
      when is_atom(mod) and mod != nil do
    mod_str = Atom.to_string(mod)

    if String.ends_with?(mod_str, "Routes") or String.ends_with?(mod_str, ".VerifiedRoutes"),
      do: :pure
  end

  def classify_effect(_), do: nil

  @param_names [:params, :user_params, :body_params]

  @impl true
  def trace_pattern(pattern) when pattern in ["conn.params", "params"] do
    fn node ->
      node.type == :var and node.meta[:name] in @param_names
    end
  end

  def trace_pattern(_pattern), do: nil

  @impl true
  def behaviour_label(callbacks) do
    if :mount in callbacks and :render in callbacks, do: "LiveView"
  end

  @impl true
  def analyze(all_nodes, _opts) do
    conn_param_to_action_edges(all_nodes) ++
      action_fallback_edges(all_nodes) ++
      socket_assign_edges(all_nodes)
  end

  @impl true
  def analyze_project(_modules, all_nodes, _opts) do
    plug_chain_edges(all_nodes)
  end

  defp conn_param_to_action_edges(all_nodes) do
    func_defs = Enum.filter(all_nodes, &(&1.type == :function_def))

    Enum.flat_map(func_defs, fn func ->
      clauses = Enum.filter(func.children, &(&1.type == :clause))

      conn_params =
        clauses
        |> Enum.flat_map(fn clause ->
          clause.children
          |> Enum.take(func.meta[:arity] || 0)
          |> Enum.flat_map(&find_pattern_vars/1)
        end)
        |> Enum.filter(&(&1.meta[:name] in [:params, :user_params, :body_params]))

      for var <- conn_params do
        {var.id, func.id, :phoenix_params}
      end
    end)
  end

  defp action_fallback_edges(all_nodes) do
    fallbacks =
      Enum.filter(all_nodes, fn n ->
        n.type == :call and n.meta[:function] == :action_fallback
      end)

    case fallbacks do
      [] ->
        []

      [fallback | _] ->
        all_nodes
        |> Enum.filter(&(&1.type == :function_def))
        |> Enum.flat_map(&error_tuples_in/1)
        |> Enum.map(fn err -> {err.id, fallback.id, :phoenix_action_fallback} end)
    end
  end

  defp socket_assign_edges(all_nodes) do
    assigns =
      Enum.filter(all_nodes, fn n ->
        n.type == :call and n.meta[:function] == :assign and
          n.meta[:module] in @assign_modules
      end)

    for assign_call <- assigns,
        arg <- assign_call.children,
        var <- find_vars_in(arg) do
      {var.id, assign_call.id, :phoenix_assign}
    end
  end

  defp plug_chain_edges(all_nodes) do
    scope_blocks =
      Enum.filter(all_nodes, fn n ->
        n.type == :call and n.meta[:function] in [:scope, :pipeline]
      end)

    scope_blocks
    |> Enum.flat_map(fn scope ->
      scope_nodes = IR.all_nodes(scope)

      pipe_throughs =
        Enum.filter(scope_nodes, fn n ->
          n.type == :call and n.meta[:function] == :pipe_through
        end)

      routes =
        Enum.filter(scope_nodes, fn n ->
          n.type == :call and
            n.meta[:function] in [:get, :post, :put, :patch, :delete, :resources]
        end)

      for pt <- pipe_throughs, route <- routes do
        {pt.id, route.id, :phoenix_plug_chain}
      end
    end)
  end

  defp error_tuples_in(func) do
    func |> IR.all_nodes() |> Enum.filter(&error_tuple?/1)
  end

  defp error_tuple?(node) do
    node.type == :tuple and
      match?([%{type: :literal, meta: %{value: :error}} | _], node.children)
  end

  defp find_pattern_vars(node) do
    node
    |> IR.all_nodes()
    |> Enum.filter(fn n -> n.type == :var and n.meta[:binding_role] == :definition end)
  end
end
