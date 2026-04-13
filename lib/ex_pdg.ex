defmodule ExPDG do
  @moduledoc """
  Program Dependence Graph for BEAM languages.

  ExPDG analyzes Elixir source code and builds a graph that captures
  **what depends on what**: which expressions produce values consumed
  by others (data dependence), and which expressions control whether
  others execute (control dependence).

  ## Building a graph

      {:ok, graph} = ExPDG.string_to_graph(\"""
      def foo(x) do
        y = x + 1
        if y > 10 do
          :big
        else
          :small
        end
      end
      \""")

      {:ok, graph} = ExPDG.file_to_graph("lib/my_module.ex")

  ## Querying

      # What affects this node?
      ExPDG.backward_slice(graph, node_id)

      # What does this node affect?
      ExPDG.forward_slice(graph, node_id)

      # Can these two expressions be safely reordered?
      ExPDG.independent?(graph, id_a, id_b)

      # Find all nodes of a type
      ExPDG.nodes(graph, type: :call, module: Enum)

      # Does data flow from source to sink?
      ExPDG.data_flows?(graph, source_id, sink_id)

  ## Inspecting nodes

      node = ExPDG.node(graph, some_id)
      node.type       #=> :call
      node.meta       #=> %{module: Enum, function: :map, arity: 2}
      node.source_span #=> %{file: "lib/foo.ex", start_line: 5, ...}

      ExPDG.pure?(node)  #=> true
  """

  alias ExPDG.{Effects, Query, SystemDependence}
  alias ExPDG.IR.Node

  @type graph :: SystemDependence.t()

  # --- Building ---

  @doc """
  Parses an Elixir source string and builds a program dependence graph.

  Returns `{:ok, graph}` or `{:error, reason}`.

  ## Options

    * `:file` — filename for source locations (default: `"nofile"`)
    * `:module` — module name for call graph resolution
  """
  @spec string_to_graph(String.t(), keyword()) :: {:ok, graph()} | {:error, term()}
  def string_to_graph(source, opts \\ []) do
    SystemDependence.from_string(source, opts)
  end

  @doc """
  Same as `string_to_graph/2` but raises on parse error.
  """
  @spec string_to_graph!(String.t(), keyword()) :: graph()
  def string_to_graph!(source, opts \\ []) do
    case string_to_graph(source, opts) do
      {:ok, graph} -> graph
      {:error, reason} -> raise "ExPDG parse error: #{inspect(reason)}"
    end
  end

  @doc """
  Reads an Elixir source file and builds a program dependence graph.

  Returns `{:ok, graph}` or `{:error, reason}`.
  """
  @spec file_to_graph(Path.t(), keyword()) :: {:ok, graph()} | {:error, term()}
  def file_to_graph(path, opts \\ []) do
    case File.read(path) do
      {:ok, source} ->
        opts = Keyword.merge([file: path, module: module_from_path(path)], opts)
        string_to_graph(source, opts)

      {:error, reason} ->
        {:error, {:file, reason}}
    end
  end

  @doc """
  Same as `file_to_graph/2` but raises on error.
  """
  @spec file_to_graph!(Path.t(), keyword()) :: graph()
  def file_to_graph!(path, opts \\ []) do
    case file_to_graph(path, opts) do
      {:ok, graph} -> graph
      {:error, reason} -> raise "ExPDG error: #{inspect(reason)}"
    end
  end

  # --- Slicing ---

  @doc """
  Returns all node IDs that affect the given node (backward slice).

  The backward slice answers: "what does this expression depend on?"
  """
  defdelegate backward_slice(graph, node_id), to: ExPDG.Graph

  @doc """
  Returns all node IDs affected by the given node (forward slice).

  The forward slice answers: "what does this expression influence?"
  """
  defdelegate forward_slice(graph, node_id), to: ExPDG.Graph

  @doc """
  Returns node IDs on all paths from `source` to `sink`.

  The chop answers: "how does A influence B?"
  """
  defdelegate chop(graph, source, sink), to: ExPDG.Graph

  # --- Independence ---

  @doc """
  Returns true if two expressions are independent.

  Two expressions are independent when:
  1. No data flows between them in either direction
  2. They execute under the same conditions (same control dependencies)
  3. Their side effects don't conflict

  Independent expressions can be safely reordered.
  """
  @spec independent?(graph(), Node.id(), Node.id()) :: boolean()
  def independent?(graph, id_x, id_y) do
    ExPDG.Graph.independent?(unwrap(graph), id_x, id_y)
  end

  # --- Querying nodes ---

  @doc """
  Returns all IR nodes, optionally filtered.

  ## Options

    * `:type` — filter by node type (`:call`, `:match`, `:var`, etc.)
    * `:module` — filter calls by module
    * `:function` — filter calls by function name

  ## Examples

      ExPDG.nodes(graph, type: :call)
      ExPDG.nodes(graph, type: :call, module: Enum)
  """
  @spec nodes(graph(), keyword()) :: [Node.t()]
  defdelegate nodes(graph, opts \\ []), to: Query

  @doc """
  Returns the IR node for a given ID, or `nil`.
  """
  @spec node(graph(), Node.id()) :: Node.t() | nil
  def node(%SystemDependence{nodes: nodes}, id), do: Map.get(nodes, id)

  @doc """
  Returns true if there's a data-dependence path from `source` to `sink`.
  """
  defdelegate data_flows?(graph, source_id, sink_id), to: Query

  @doc """
  Returns true if `controller` has a control-dependence edge to `target`.
  """
  defdelegate controls?(graph, controller_id, target_id), to: Query

  @doc """
  Returns true if there's any dependence path between two nodes.
  """
  defdelegate depends?(graph, id_a, id_b), to: Query

  @doc """
  Returns true if the node has data dependents (its value is used elsewhere).
  """
  defdelegate has_dependents?(graph, node_id), to: Query

  @doc """
  Returns true if the path from `source` to `sink` passes through
  any node matching `predicate`.

  Useful for taint analysis — check if sanitization occurs between
  a source and sink.
  """
  defdelegate passes_through?(graph, source_id, sink_id, predicate), to: Query

  # --- Effects ---

  @doc """
  Returns true if the node is pure (no side effects).
  """
  @spec pure?(Node.t()) :: boolean()
  defdelegate pure?(node), to: Effects

  @doc """
  Returns the effect classification of a node.

  Possible values: `:pure`, `:read`, `:write`, `:io`, `:send`,
  `:receive`, `:exception`, `:nif`, `:unknown`.
  """
  @spec classify_effect(Node.t()) :: Effects.effect()
  defdelegate classify_effect(node), to: Effects, as: :classify

  # --- Graph access ---

  @doc """
  Returns all dependence edges in the graph.
  """
  @spec edges(graph()) :: [Graph.Edge.t()]
  def edges(%SystemDependence{graph: graph}), do: Elixir.Graph.edges(graph)

  @doc """
  Returns the control dependencies of a node.

  Each entry is `{controller_node_id, label}`.
  """
  @spec control_deps(graph(), Node.id()) :: [{Node.id(), term()}]
  def control_deps(%SystemDependence{} = sdg, node_id) do
    ExPDG.Graph.control_deps(unwrap(sdg), node_id)
  end

  @doc """
  Returns the data dependencies of a node.

  Each entry is `{source_node_id, variable_name}`.
  """
  @spec data_deps(graph(), Node.id()) :: [{Node.id(), atom()}]
  def data_deps(%SystemDependence{} = sdg, node_id) do
    ExPDG.Graph.data_deps(unwrap(sdg), node_id)
  end

  @doc """
  Returns the per-function PDG for a `{module, function, arity}` tuple.
  """
  @spec function_graph(graph(), SystemDependence.function_id()) :: ExPDG.Graph.t() | nil
  defdelegate function_graph(graph, function_id), to: SystemDependence, as: :function_pdg

  @doc """
  Performs a context-sensitive backward slice through call boundaries.

  Uses the Horwitz-Reps-Binkley two-phase algorithm to avoid
  impossible paths through call sites.
  """
  @spec context_sensitive_slice(graph(), Node.id()) :: [Node.id()]
  defdelegate context_sensitive_slice(graph, node_id), to: SystemDependence

  @doc """
  Returns the call graph as a `Graph.t()`.

  Vertices are `{module, function, arity}` tuples.
  """
  @spec call_graph(graph()) :: Graph.t()
  def call_graph(%SystemDependence{call_graph: cg}), do: cg

  @doc """
  Exports the graph to DOT format for Graphviz visualization.
  """
  @spec to_dot(graph()) :: {:ok, String.t()}
  def to_dot(%SystemDependence{graph: graph}), do: Elixir.Graph.to_dot(graph)

  # --- Private ---

  defp unwrap(%SystemDependence{} = sdg) do
    %ExPDG.Graph{
      graph: sdg.graph,
      ir: sdg.ir,
      control_flow: sdg.call_graph,
      nodes: sdg.nodes
    }
  end

  defp module_from_path(path) do
    path
    |> Path.rootname()
    |> Path.split()
    |> Enum.drop_while(&(&1 != "lib"))
    |> Enum.drop(1)
    |> Enum.map_join(".", &Macro.camelize/1)
    |> then(fn
      "" -> nil
      name -> Module.concat([name])
    end)
  end
end
