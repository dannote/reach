defmodule Reach.DependencySummary do
  @moduledoc "Summarizes function dependencies (callers, callees, shared state)."

  alias Reach.{Frontend, IR}

  import Reach.IR.Helpers, only: [param_var_name: 1, var_used_in_subtree?: 2]

  @spec summarize(module()) :: %{{module(), atom(), non_neg_integer()} => map()}
  def summarize(module) do
    case Frontend.BEAM.from_module(module) do
      {:ok, ir_nodes} ->
        ir_nodes
        |> IR.all_nodes()
        |> Enum.filter(&(&1.type == :function_def))
        |> Map.new(fn func_def ->
          func_id = {module, func_def.meta[:name], func_def.meta[:arity]}
          {func_id, compute_param_flows(func_def)}
        end)

      {:error, _} ->
        %{}
    end
  end

  defp compute_param_flows(func_def) do
    case func_def.children do
      [%{type: :clause, children: children, meta: %{kind: :function_clause}} | _] ->
        arity = func_def.meta[:arity] || 0
        params = Enum.take(children, arity)
        return_nodes = find_return_expressions(func_def)

        params
        |> Enum.with_index()
        |> Map.new(fn {param, index} ->
          var_name = param_var_name(param)

          flows =
            var_name != nil and
              Enum.any?(return_nodes, &var_used_in_subtree?(&1, var_name))

          {index, flows}
        end)

      _ ->
        %{}
    end
  end

  defp find_return_expressions(func_def) do
    func_def
    |> IR.all_nodes()
    |> Enum.filter(&(&1.type == :clause and &1.meta[:kind] == :function_clause))
    |> Enum.flat_map(fn clause ->
      case clause.children do
        [] -> []
        children -> [Enum.at(children, -1)]
      end
    end)
  end
end
