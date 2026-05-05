defmodule Reach.Plugins.Oban do
  @moduledoc "Plugin for Oban worker and job semantics."
  @behaviour Reach.Plugin

  alias Reach.IR
  alias Reach.IR.Node

  @impl true
  def behaviour_label(callbacks) do
    if :perform in callbacks, do: "Oban.Worker"
  end

  @impl true
  def classify_effect(%Node{type: :call, meta: %{module: Oban, function: fun}})
      when fun in [:insert, :insert!, :insert_all, :insert_all!],
      do: :write

  def classify_effect(%Node{type: :call, meta: %{module: Oban, function: fun}})
      when fun in [:start_link, :stop, :drain_queue],
      do: :io

  def classify_effect(_), do: nil

  @impl true
  def analyze(all_nodes, _opts) do
    job_args_edges(all_nodes)
  end

  @impl true
  def analyze_project(_modules, all_nodes, _opts) do
    enqueue_to_perform_edges(all_nodes)
  end

  defp job_args_edges(all_nodes) do
    perform_fns =
      Enum.filter(all_nodes, fn n ->
        n.type == :function_def and n.meta[:name] == :perform
      end)

    Enum.flat_map(perform_fns, fn func ->
      param_names = perform_param_names(func)

      func
      |> IR.all_nodes()
      |> Enum.filter(fn n ->
        n.type == :var and n.meta[:name] in param_names and
          n.meta[:binding_role] != :definition
      end)
      |> Enum.map(fn var_use -> {func.id, var_use.id, :oban_job_args} end)
    end)
  end

  defp enqueue_to_perform_edges(all_nodes) do
    inserts =
      Enum.filter(all_nodes, fn n ->
        n.type == :call and n.meta[:module] == Oban and
          n.meta[:function] in [:insert, :insert!]
      end)

    performs =
      Enum.filter(all_nodes, fn n ->
        n.type == :function_def and n.meta[:name] == :perform
      end)

    performs_by_module =
      Map.new(performs, fn p -> {p.meta[:module], p} end)

    Enum.flat_map(inserts, &enqueue_edges(&1, performs_by_module))
  end

  defp enqueue_edges(insert, performs_by_module) do
    with worker_mod when worker_mod != nil <- extract_worker_module(insert),
         %{} = perform <- Map.get(performs_by_module, worker_mod) do
      [{insert.id, perform.id, :oban_enqueue}]
    else
      _ -> []
    end
  end

  defp extract_worker_module(insert_call) do
    insert_call
    |> IR.all_nodes()
    |> Enum.find_value(fn n ->
      if n.type == :call and n.meta[:function] == :new and n.meta[:module] do
        n.meta[:module]
      end
    end)
  end

  defp perform_param_names(func) do
    func.children
    |> Enum.filter(&(&1.type == :clause))
    |> Enum.flat_map(fn clause ->
      clause.children
      |> Enum.filter(fn n ->
        n.type == :var and n.meta[:binding_role] == :definition
      end)
      |> Enum.map(& &1.meta[:name])
    end)
    |> Enum.uniq()
  end
end
