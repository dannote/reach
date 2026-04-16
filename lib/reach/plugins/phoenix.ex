defmodule Reach.Plugins.Phoenix do
  @moduledoc false
  @behaviour Reach.Plugin

  alias Reach.IR

  import Reach.Plugins.Helpers, only: [find_vars_in: 1]

  @assign_modules [nil, Phoenix.Component, Phoenix.LiveView]

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

  # conn params pattern var → enclosing function_def
  # Marks the function as receiving untrusted input
  defp conn_param_to_action_edges(all_nodes) do
    func_defs =
      Enum.filter(all_nodes, &(&1.type == :function_def))

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

  # action_fallback — scoped: error tuples within each function_def
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

  # socket assigns: assign(socket, :key, val)
  # Also matches Phoenix.Component.assign and Phoenix.LiveView.assign
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

  # Plug chains: pipe_through → route macros within the same scope block
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
