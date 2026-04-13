defmodule Reach.SystemDependence do
  @moduledoc false

  alias Reach.{CallGraph, ControlDependence, ControlFlow, DataDependence, IR, OTP}
  alias Reach.IR.Node

  @type function_id :: CallGraph.function_id()

  @type t :: %__MODULE__{
          graph: Graph.t(),
          function_pdgs: %{function_id() => Reach.Graph.t()},
          call_graph: Graph.t(),
          ir: [Node.t()],
          nodes: %{Node.id() => Node.t()}
        }

  @enforce_keys [:graph, :function_pdgs, :call_graph, :ir, :nodes]
  defstruct [:graph, :function_pdgs, :call_graph, :ir, :nodes]

  @doc """
  Builds an SDG from Elixir source containing one or more function definitions.
  """
  @spec from_string(String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def from_string(source, opts \\ []) do
    case IR.from_string(source, opts) do
      {:ok, nodes} -> {:ok, build(nodes, opts)}
      {:error, _} = err -> err
    end
  end

  @doc """
  Builds an SDG from IR nodes.
  """
  @spec build([Node.t()], keyword()) :: t()
  def build(ir_nodes, opts \\ []) do
    module_name = Keyword.get(opts, :module)
    all_nodes = IR.all_nodes(ir_nodes)
    node_map = Map.new(all_nodes, fn n -> {n.id, n} end)

    func_defs = CallGraph.collect_function_defs(all_nodes, module_name)
    call_graph = CallGraph.build(ir_nodes, module: module_name, all_nodes: all_nodes)

    function_pdgs = build_function_pdgs(func_defs)

    graph = merge_function_pdgs(function_pdgs)
    graph = add_call_edges(graph, all_nodes, func_defs, function_pdgs)
    graph = add_summary_edges(graph, all_nodes, func_defs, function_pdgs)

    otp_edges = OTP.analyze(ir_nodes, all_nodes: all_nodes)
    concurrency_edges = Reach.Concurrency.analyze(ir_nodes, all_nodes: all_nodes)
    graph = Reach.GraphUtils.merge(graph, otp_edges)
    graph = Reach.GraphUtils.merge(graph, concurrency_edges)

    %__MODULE__{
      graph: graph,
      function_pdgs: function_pdgs,
      call_graph: call_graph,
      ir: ir_nodes,
      nodes: node_map
    }
  end

  @doc """
  Context-sensitive backward slice using Horwitz-Reps-Binkley two-phase algorithm.

  Phase 1: slice backward in calling context — follow call edges down,
           don't follow return edges up.
  Phase 2: from Phase 1 results, slice backward in called context —
           follow return edges up, don't follow call edges down.
  """
  @spec context_sensitive_slice(t(), Node.id()) :: [Node.id()]
  def context_sensitive_slice(%__MODULE__{graph: graph}, node_id) do
    phase1 = slice_phase(graph, [node_id], MapSet.new(), :phase1)
    phase2 = slice_phase(graph, MapSet.to_list(phase1), phase1, :phase2)
    MapSet.union(phase1, phase2) |> MapSet.delete(node_id) |> MapSet.to_list()
  end

  @doc """
  Returns the PDG for a specific function.
  """
  @spec function_pdg(t(), function_id()) :: Reach.Graph.t() | nil
  def function_pdg(%__MODULE__{function_pdgs: pdgs}, function_id) do
    Map.get(pdgs, function_id)
  end

  @doc """
  Exports the SDG to DOT format.
  """
  @spec to_dot(t()) :: {:ok, String.t()} | {:error, term()}
  def to_dot(%__MODULE__{graph: graph}) do
    Graph.to_dot(graph)
  end

  # --- Private: PDG construction ---

  defp build_function_pdgs(func_defs) do
    Map.new(func_defs, fn {func_id, func_node} ->
      flow = ControlFlow.build(func_node)
      control_deps = ControlDependence.build(flow)
      data_deps = DataDependence.build(func_node)

      all_func_nodes = IR.all_nodes(func_node)
      node_map = Map.new(all_func_nodes, fn n -> {n.id, n} end)

      merged = Reach.GraphUtils.merge(control_deps, data_deps)

      pdg = %Reach.Graph{
        graph: merged,
        ir: [func_node],
        control_flow: flow,
        nodes: node_map
      }

      {func_id, pdg}
    end)
  end

  defp merge_function_pdgs(function_pdgs) do
    function_pdgs
    |> Enum.flat_map(fn {_func_id, pdg} -> Graph.edges(pdg.graph) end)
    |> then(&Graph.add_edges(Graph.new(), &1))
  end

  # --- Private: interprocedural edges ---

  defp add_call_edges(graph, all_nodes, func_defs, function_pdgs) do
    func_map = Map.new(func_defs)

    call_nodes = Enum.filter(all_nodes, &(&1.type == :call))

    Enum.reduce(call_nodes, graph, fn call_node, g ->
      callee_id =
        {call_node.meta[:module], call_node.meta[:function], call_node.meta[:arity] || 0}

      case Map.get(func_map, callee_id) do
        nil ->
          g

        callee_def ->
          g = Graph.add_vertex(g, call_node.id)
          g = Graph.add_vertex(g, callee_def.id)
          g = Graph.add_edge(g, call_node.id, callee_def.id, label: :call)

          g = connect_parameters(g, call_node, callee_def, function_pdgs, callee_id)
          connect_return_value(g, call_node, callee_def)
      end
    end)
  end

  defp connect_parameters(graph, call_node, callee_def, _function_pdgs, _callee_id) do
    callee_params = extract_formal_params(callee_def)
    actual_args = call_node.children

    Enum.zip(actual_args, callee_params)
    |> Enum.reduce(graph, fn {actual, formal}, g ->
      g
      |> Graph.add_vertex(actual.id)
      |> Graph.add_vertex(formal.id)
      |> Graph.add_edge(actual.id, formal.id, label: :parameter_in)
    end)
  end

  defp connect_return_value(graph, call_node, callee_def) do
    case find_return_nodes(callee_def) do
      [] ->
        graph

      return_nodes ->
        Enum.reduce(return_nodes, graph, fn ret_node, g ->
          g
          |> Graph.add_vertex(ret_node.id)
          |> Graph.add_vertex(call_node.id)
          |> Graph.add_edge(ret_node.id, call_node.id, label: :parameter_out)
        end)
    end
  end

  # --- Private: summary edges ---

  defp add_summary_edges(graph, all_nodes, func_defs, function_pdgs) do
    func_map = Map.new(func_defs)
    call_nodes = Enum.filter(all_nodes, &(&1.type == :call))

    Enum.reduce(call_nodes, graph, fn call_node, g ->
      callee_id =
        {call_node.meta[:module], call_node.meta[:function], call_node.meta[:arity] || 0}

      case {Map.get(func_map, callee_id), Map.get(function_pdgs, callee_id)} do
        {nil, _} ->
          g

        {_, nil} ->
          g

        {callee_def, callee_pdg} ->
          add_summaries_for_call(g, call_node, callee_def, callee_pdg)
      end
    end)
  end

  defp add_summaries_for_call(graph, call_node, callee_def, _callee_pdg) do
    formal_params = extract_formal_params(callee_def)
    return_nodes = find_return_nodes(callee_def)
    actual_args = call_node.children

    param_pairs = Enum.zip(actual_args, formal_params)

    Enum.reduce(param_pairs, graph, fn {actual_in, formal_in}, g ->
      var_name = param_var_name(formal_in)

      flows_to_return =
        var_name != nil and
          Enum.any?(return_nodes, &var_used_in_subtree?(&1, var_name))

      if flows_to_return do
        g
        |> Graph.add_vertex(actual_in.id)
        |> Graph.add_vertex(call_node.id)
        |> Graph.add_edge(actual_in.id, call_node.id, label: :summary)
      else
        g
      end
    end)
  end

  defp param_var_name(%Node{type: :var, meta: %{name: name}}), do: name
  defp param_var_name(_), do: nil

  defp var_used_in_subtree?(%Node{type: :var, meta: %{name: name}}, target_name) do
    name == target_name
  end

  defp var_used_in_subtree?(%Node{children: children}, target_name) do
    Enum.any?(children, &var_used_in_subtree?(&1, target_name))
  end

  # --- Private: slicing ---

  defp slice_phase(_graph, [], visited, _phase), do: visited

  defp slice_phase(graph, worklist, visited, phase) do
    Enum.reduce(worklist, visited, fn node_id, acc ->
      if MapSet.member?(acc, node_id) do
        acc
      else
        acc = MapSet.put(acc, node_id)

        predecessors =
          graph
          |> Graph.in_edges(node_id)
          |> Enum.filter(&edge_allowed?(&1.label, phase))
          |> Enum.map(& &1.v1)
          |> Enum.reject(&MapSet.member?(acc, &1))

        slice_phase(graph, predecessors, acc, phase)
      end
    end)
  end

  # Phase 1: follow everything except parameter_out (return edges)
  defp edge_allowed?(:parameter_out, :phase1), do: false
  defp edge_allowed?(_label, :phase1), do: true

  # Phase 2: follow everything except call and parameter_in
  defp edge_allowed?(:call, :phase2), do: false
  defp edge_allowed?(:parameter_in, :phase2), do: false
  defp edge_allowed?(_label, :phase2), do: true

  # --- Private: helpers ---

  defp extract_formal_params(func_def) do
    case func_def.children do
      [%Node{type: :clause, children: children} | _] ->
        Enum.take_while(children, fn n ->
          n.type not in [:guard, :block, :call, :binary_op, :case, :literal]
        end)

      _ ->
        []
    end
  end

  defp find_return_nodes(func_def) do
    all = IR.all_nodes(func_def)

    last_expressions =
      Enum.filter(all, fn node ->
        node.type == :clause and node.meta[:kind] == :function_clause
      end)
      |> Enum.flat_map(fn clause ->
        case List.last(clause.children) do
          nil -> []
          last -> [last]
        end
      end)

    case last_expressions do
      [] -> all |> Enum.filter(&(&1.type not in [:function_def, :clause, :guard]))
      exprs -> exprs
    end
  end
end
