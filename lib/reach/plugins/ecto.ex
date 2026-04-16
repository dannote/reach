defmodule Reach.Plugins.Ecto do
  @moduledoc false
  @behaviour Reach.Plugin

  alias Reach.IR

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
    :insert_all!
  ]

  @impl true
  def analyze(all_nodes, _opts) do
    changeset_to_repo_edges(all_nodes) ++
      raw_query_edges(all_nodes) ++
      cast_field_edges(all_nodes)
  end

  # Changeset → Repo.insert: scoped to the same function_def
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

  # Raw SQL: Repo.query("SELECT ...") or Ecto.Adapters.SQL.query
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

  # cast(changeset, params, [:field1, :field2]) — track which fields are cast
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

  defp repo_module?(nil), do: false

  defp repo_module?(mod) when is_atom(mod) do
    mod_str = Atom.to_string(mod)
    String.ends_with?(mod_str, "Repo") or String.ends_with?(mod_str, ".Repo")
  end
end
