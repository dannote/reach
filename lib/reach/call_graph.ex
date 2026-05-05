defmodule Reach.CallGraph do
  @moduledoc "Builds call graph edges between function definitions."

  alias Reach.IR
  alias Reach.IR.Node

  @type function_id :: {module(), atom(), non_neg_integer()}

  @doc """
  Builds a call graph from a list of IR nodes (typically a whole module).

  Returns a `Graph.t()` where vertices are `{module, function, arity}` tuples
  and edges are labeled with the call site node ID.
  """
  @spec build([Node.t()], keyword()) :: Graph.t()
  def build(ir_nodes, opts \\ []) do
    module_name = Keyword.get(opts, :module)
    all_nodes = Keyword.get_lazy(opts, :all_nodes, fn -> IR.all_nodes(ir_nodes) end)

    func_defs = collect_function_defs(all_nodes, module_name)
    call_sites = collect_call_sites(all_nodes)

    graph =
      Enum.reduce(func_defs, Graph.new(), fn {fun_id, _node}, g ->
        Graph.add_vertex(g, fun_id)
      end)

    Enum.reduce(call_sites, graph, fn {caller_id, callee_id, call_node_id}, g ->
      g
      |> Graph.add_vertex(caller_id)
      |> Graph.add_vertex(callee_id)
      |> Graph.add_edge(caller_id, callee_id, label: {:call, call_node_id})
    end)
  end

  @doc """
  Collects all function definitions as `{function_id, ir_node}` pairs.
  """
  @spec collect_function_defs([Node.t()], module() | nil) :: [{function_id(), Node.t()}]
  def collect_function_defs(all_nodes, module_name) do
    for node <- all_nodes,
        node.type == :function_def,
        name = node.meta[:name],
        arity = node.meta[:arity],
        name != nil do
      {{module_name, name, arity}, node}
    end
  end

  @doc """
  Finds which function definition contains a given node, based on the IR tree.
  """
  @spec find_enclosing_function([Node.t()], Node.id()) :: function_id() | nil
  def find_enclosing_function(ir_nodes, target_id) do
    find_enclosing(ir_nodes, target_id, nil)
  end

  defp find_enclosing(nodes, target_id, current_func) when is_list(nodes) do
    Enum.find_value(nodes, fn node -> find_enclosing(node, target_id, current_func) end)
  end

  defp find_enclosing(%Node{id: id, type: :function_def} = node, target_id, _current_func) do
    func_id = {nil, node.meta[:name], node.meta[:arity]}

    if id == target_id do
      func_id
    else
      find_enclosing(node.children, target_id, func_id)
    end
  end

  defp find_enclosing(%Node{id: id} = node, target_id, current_func) do
    if id == target_id do
      current_func
    else
      find_enclosing(node.children, target_id, current_func)
    end
  end

  defp collect_call_sites(all_nodes) do
    parent_map = build_parent_map(all_nodes)

    for call_node <- all_nodes,
        call_node.type == :call,
        caller_def = Map.get(parent_map, call_node.id),
        caller_def != nil do
      caller_id = {nil, caller_def.meta[:name], caller_def.meta[:arity]}
      callee_id = call_target(call_node)
      {caller_id, callee_id, call_node.id}
    end
  end

  defp build_parent_map(all_nodes) do
    func_defs = Enum.filter(all_nodes, &(&1.type == :function_def))

    Enum.reduce(func_defs, %{}, fn func_def, acc ->
      func_def
      |> Reach.IR.all_nodes()
      |> Enum.reduce(acc, &Map.put_new(&2, &1.id, func_def))
    end)
  end

  defp call_target(%Node{type: :call, meta: meta}) do
    {meta[:module], meta[:function], meta[:arity] || 0}
  end
end
