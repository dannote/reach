defmodule Reach.OTP.CrossProcess do
  @moduledoc "Analyzes cross-process data dependencies by tracing effects through GenServer call/cast boundaries."

  alias Reach.Analysis
  alias Reach.IR
  alias Reach.IR.Node

  @type effect_summary :: %{
          module: module(),
          ets_writes: [atom()],
          ets_reads: [atom()],
          pdict_writes: [atom()],
          pdict_reads: [atom()],
          sends_to: [module()]
        }

  @doc """
  Builds a per-module effect summary: which ETS tables, pdict keys,
  and other processes each module touches.
  """
  @spec build_effect_summaries([Node.t()], keyword()) :: %{module() => effect_summary()}
  def build_effect_summaries(nodes, opts \\ []) do
    all = Keyword.get_lazy(opts, :all_nodes, fn -> Enum.flat_map(nodes, &IR.all_nodes/1) end)

    all
    |> Enum.filter(&(&1.type == :module_def))
    |> Map.new(fn mod_node ->
      {mod_node.meta[:name], summarize_effects(mod_node.meta[:name], IR.all_nodes(mod_node))}
    end)
  end

  @doc """
  Finds cross-process coupling: when module A calls GenServer.call(B, ...)
  and module B touches ETS tables or pdict keys that module A also uses.
  """
  @spec find_cross_process_coupling([Node.t()], keyword()) :: [map()]
  def find_cross_process_coupling(nodes, opts \\ []) do
    all_nodes =
      Keyword.get_lazy(opts, :all_nodes, fn -> Enum.flat_map(nodes, &IR.all_nodes/1) end)

    summaries = build_effect_summaries(nodes, all_nodes: all_nodes)
    module_nodes = Enum.filter(all_nodes, &(&1.type == :module_def))
    module_index = build_module_index(module_nodes)

    gs_calls = Enum.filter(all_nodes, &genserver_send?/1)

    Enum.flat_map(gs_calls, fn call ->
      caller_mod = Map.get(module_index, call.id)
      callee_mod = resolve_call_target(call)

      if caller_mod && callee_mod && caller_mod != callee_mod do
        detect_coupling(call, caller_mod, callee_mod, summaries)
      else
        []
      end
    end)
  end

  defp summarize_effects(mod_name, all_nodes) do
    %{
      module: mod_name,
      ets_writes: find_ets_tables(all_nodes, :write),
      ets_reads: find_ets_tables(all_nodes, :read),
      pdict_writes: find_pdict_keys(all_nodes, :write),
      pdict_reads: find_pdict_keys(all_nodes, :read),
      sends_to: find_send_targets(all_nodes)
    }
  end

  @ets_write_ops [:insert, :insert_new, :delete, :delete_object, :update_counter, :update_element]
  @ets_read_ops [:lookup, :lookup_element, :match, :match_object, :select, :member]

  defp find_ets_tables(all_nodes, direction) do
    ops =
      case direction do
        :write -> @ets_write_ops
        :read -> @ets_read_ops
      end

    all_nodes
    |> Enum.filter(fn n ->
      n.type == :call and n.meta[:module] == :ets and n.meta[:function] in ops
    end)
    |> Enum.flat_map(&extract_table_name/1)
    |> Enum.uniq()
  end

  defp extract_table_name(%{children: [%{type: :literal, meta: %{value: name}} | _]})
       when is_atom(name),
       do: [name]

  defp extract_table_name(_), do: []

  defp find_pdict_keys(all_nodes, direction) do
    fns =
      case direction do
        :write -> [:put, :delete]
        :read -> [:get, :get_keys]
      end

    all_nodes
    |> Enum.filter(fn n ->
      n.type == :call and n.meta[:module] == Process and n.meta[:function] in fns
    end)
    |> Enum.flat_map(fn n ->
      case n.children do
        [%{type: :literal, meta: %{value: key}} | _] -> [key]
        _ -> []
      end
    end)
    |> Enum.uniq()
  end

  defp find_send_targets(all_nodes) do
    all_nodes
    |> Enum.filter(&genserver_send?/1)
    |> Enum.flat_map(fn call ->
      case resolve_call_target(call) do
        nil -> []
        mod -> [mod]
      end
    end)
    |> Enum.uniq()
  end

  defp genserver_send?(%Node{type: :call, meta: %{module: GenServer, function: f}})
       when f in [:call, :cast],
       do: true

  defp genserver_send?(%Node{type: :call, meta: %{module: :gen_server, function: f}})
       when f in [:call, :cast],
       do: true

  defp genserver_send?(_), do: false

  defp resolve_call_target(node), do: Analysis.call_target(node)

  defp detect_coupling(call, caller_mod, callee_mod, summaries) do
    caller_summary = Map.get(summaries, caller_mod)
    callee_summary = Map.get(summaries, callee_mod)

    if caller_summary == nil or callee_summary == nil do
      []
    else
      ets_conflicts = find_ets_conflicts(caller_summary, callee_summary)
      pdict_conflicts = find_pdict_conflicts(caller_summary, callee_summary)

      build_findings(call, caller_mod, callee_mod, ets_conflicts, pdict_conflicts)
    end
  end

  defp find_ets_conflicts(caller, callee) do
    caller_tables = MapSet.new(caller.ets_reads ++ caller.ets_writes)
    callee_writes = MapSet.new(callee.ets_writes)
    callee_reads = MapSet.new(callee.ets_reads)

    write_conflicts =
      MapSet.intersection(caller_tables, callee_writes)
      |> MapSet.to_list()
      |> Enum.map(&{&1, :callee_writes})

    read_after_write =
      MapSet.intersection(MapSet.new(caller.ets_writes), callee_reads)
      |> MapSet.to_list()
      |> Enum.map(&{&1, :callee_reads_caller_write})

    write_conflicts ++ read_after_write
  end

  defp find_pdict_conflicts(caller, callee) do
    caller_keys = MapSet.new(caller.pdict_reads ++ caller.pdict_writes)
    callee_writes = MapSet.new(callee.pdict_writes)

    MapSet.intersection(caller_keys, callee_writes)
    |> MapSet.to_list()
    |> Enum.map(&{&1, :callee_writes})
  end

  defp build_findings(_call, _caller, _callee, [], []), do: []

  defp build_findings(call, caller_mod, callee_mod, ets_conflicts, pdict_conflicts) do
    ets_findings =
      Enum.map(ets_conflicts, fn {table, kind} ->
        %{
          kind: :cross_process_ets,
          caller: caller_mod,
          callee: callee_mod,
          resource: {:ets, table},
          conflict: kind,
          call_site: call,
          location: location(call)
        }
      end)

    pdict_findings =
      Enum.map(pdict_conflicts, fn {key, kind} ->
        %{
          kind: :cross_process_pdict,
          caller: caller_mod,
          callee: callee_mod,
          resource: {:pdict, key},
          conflict: kind,
          call_site: call,
          location: location(call)
        }
      end)

    ets_findings ++ pdict_findings
  end

  defp build_module_index(module_nodes) do
    for mod <- module_nodes,
        node <- IR.all_nodes(mod),
        into: %{} do
      {node.id, mod.meta[:name]}
    end
  end

  defp location(node), do: Analysis.location(node)
end
