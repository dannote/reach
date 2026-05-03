defmodule Reach.Plugins.Ecto do
  @moduledoc false
  @behaviour Reach.Plugin

  alias Reach.IR
  alias Reach.IR.Node

  import Reach.Plugins.Helpers, only: [find_vars_in: 1]

  @repo_write_fns [
    :insert,
    :insert!,
    :update,
    :update!,
    :delete,
    :delete!,
    :insert_or_update,
    :insert_or_update!,
    :insert_all,
    :insert_all!,
    :update_all,
    :delete_all
  ]

  @repo_read_fns [
    :all,
    :one,
    :one!,
    :get,
    :get!,
    :get_by,
    :get_by!,
    :exists?,
    :aggregate,
    :preload,
    :reload,
    :reload!
  ]

  @repo_tx_fns [:transaction]

  @query_dsl [
    :from,
    :where,
    :select,
    :join,
    :group_by,
    :order_by,
    :having,
    :distinct,
    :limit,
    :offset,
    :preload,
    :subquery,
    :union,
    :union_all,
    :except,
    :intersect,
    :left_join,
    :inner_join,
    :right_join,
    :cross_join,
    :on,
    :or_where,
    :or_having,
    :select_merge,
    :windows,
    :lock,
    :combinations
  ]

  @query_expr [
    :fragment,
    :field,
    :assoc,
    :as,
    :selected_as,
    :dynamic,
    :select_merge_as,
    :type,
    :coalesce,
    :over,
    :parent_as,
    :sum,
    :count,
    :avg,
    :max,
    :min,
    :like,
    :ilike
  ]

  @changeset_fns [
    :cast,
    :validate_required,
    :validate_format,
    :validate_length,
    :validate_number,
    :validate_inclusion,
    :validate_exclusion,
    :validate_acceptance,
    :validate_confirmation,
    :validate_change,
    :validate_subset,
    :unique_constraint,
    :foreign_key_constraint,
    :no_assoc_constraint,
    :check_constraint,
    :exclusion_constraint,
    :put_change,
    :force_change,
    :put_assoc,
    :cast_assoc,
    :cast_embed,
    :change,
    :apply_changes,
    :apply_action,
    :apply_action!,
    :get_change,
    :get_field,
    :fetch_change,
    :fetch_change!,
    :fetch_field,
    :fetch_field!,
    :add_error,
    :traverse_errors,
    :delete_change,
    :merge
  ]

  @schema_fns [
    :schema,
    :embedded_schema,
    :field,
    :belongs_to,
    :has_many,
    :has_one,
    :many_to_many,
    :embeds_one,
    :embeds_many,
    :timestamps
  ]

  @impl true
  def trace_pattern(pattern) when pattern in ["Repo", "Repo.query"] do
    fn node ->
      node.type == :call and repo_call?(node)
    end
  end

  def trace_pattern(_pattern), do: nil

  @impl true
  def ignore_call_edge?(%Graph.Edge{v2: {target_module, target_function, target_arity}}) do
    cond do
      is_atom(target_module) and target_arity == 0 and field_access?(target_module) -> true
      target_function in @query_expr and target_arity <= 3 -> true
      true -> false
    end
  end

  def ignore_call_edge?(_edge), do: false

  @impl true
  def classify_effect(%Node{type: :call, meta: %{kind: :local, function: fun}})
      when fun in @query_dsl or fun in @query_expr or
             fun in @changeset_fns or fun in @schema_fns,
      do: :pure

  def classify_effect(%Node{type: :call, meta: %{kind: :remote, module: mod, function: _fun}})
      when mod in [Ecto.Changeset, Ecto.Query, Ecto.Multi],
      do: :pure

  def classify_effect(%Node{type: :call, meta: %{kind: :remote, module: mod, function: fun}})
      when is_atom(mod) and mod != nil do
    if repo_module?(mod), do: classify_repo_call(fun)
  end

  def classify_effect(_), do: nil

  defp classify_repo_call(fun) when fun in @repo_write_fns, do: :write
  defp classify_repo_call(fun) when fun in @repo_read_fns, do: :read
  defp classify_repo_call(fun) when fun in @repo_tx_fns, do: :write
  defp classify_repo_call(_), do: nil

  @impl true
  def analyze(all_nodes, _opts) do
    changeset_to_repo_edges(all_nodes) ++
      raw_query_edges(all_nodes) ++
      cast_field_edges(all_nodes)
  end

  defp changeset_to_repo_edges(all_nodes) do
    func_defs = Enum.filter(all_nodes, &(&1.type == :function_def))

    Enum.flat_map(func_defs, fn func ->
      func_nodes = IR.all_nodes(func)

      casts =
        Enum.filter(func_nodes, fn n ->
          n.type == :call and n.meta[:function] == :cast and
            n.meta[:module] in [nil, Ecto.Changeset]
        end)

      writes =
        Enum.filter(func_nodes, fn n ->
          n.type == :call and repo_module?(n.meta[:module]) and
            n.meta[:function] in @repo_write_fns
        end)

      for cast <- casts, write <- writes do
        {cast.id, write.id, {:ecto_changeset_flow, cast.meta[:function]}}
      end
    end)
  end

  defp raw_query_edges(all_nodes) do
    raw_calls =
      Enum.filter(all_nodes, fn n ->
        n.type == :call and
          n.meta[:function] in [:query, :query!] and
          (repo_module?(n.meta[:module]) or n.meta[:module] == Ecto.Adapters.SQL)
      end)

    for call <- raw_calls,
        arg <- call.children,
        var_node <- find_vars_in(arg) do
      {var_node.id, call.id, :ecto_raw_query}
    end
  end

  defp cast_field_edges(all_nodes) do
    cast_calls =
      Enum.filter(all_nodes, fn n ->
        n.type == :call and n.meta[:function] == :cast and
          n.meta[:module] in [nil, Ecto.Changeset]
      end)

    Enum.flat_map(cast_calls, &cast_param_edges/1)
  end

  defp cast_param_edges(%{children: [_changeset, params | _]} = call) do
    for var <- find_vars_in(params), do: {var.id, call.id, :ecto_cast_params}
  end

  defp cast_param_edges(_), do: []

  defp repo_call?(node) do
    repo_module?(node.meta[:module]) or node.meta[:module] == Ecto.Adapters.SQL
  end

  defp field_access?(module), do: ecto_binding?(module) or variable_access?(module)
  defp variable_access?(nil), do: false

  defp variable_access?(module) when is_atom(module) do
    name = Atom.to_string(module)

    String.first(name) == String.downcase(String.first(name)) and
      not String.starts_with?(name, "Elixir.")
  end

  defp ecto_binding?(module) when is_atom(module) do
    module
    |> Atom.to_string()
    |> then(&(byte_size(&1) <= 2 and &1 =~ ~r/^[a-z]{1,2}$/))
  end

  defp repo_module?(mod) when is_atom(mod) and not is_nil(mod) do
    mod_str = Atom.to_string(mod)
    String.ends_with?(mod_str, "Repo") or String.ends_with?(mod_str, ".Repo")
  end

  defp repo_module?(_), do: false
end
