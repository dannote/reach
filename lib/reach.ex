defmodule Reach do
  @moduledoc """
  Program Dependence Graph for Elixir and Erlang.

  Reach analyzes Elixir and Erlang source code and builds a graph that captures
  **what depends on what**: which expressions produce values consumed
  by others (data dependence), and which expressions control whether
  others execute (control dependence).

  ## Building a graph

      # Elixir (default)
      {:ok, graph} = Reach.string_to_graph(\"""
      def foo(x) do
        y = x + 1
        if y > 10, do: :big, else: :small
      end
      \""")

      # Erlang
      {:ok, graph} = Reach.string_to_graph(source, language: :erlang)

      # Auto-detected from file extension
      {:ok, graph} = Reach.file_to_graph("lib/my_module.ex")
      {:ok, graph} = Reach.file_to_graph("src/my_module.erl")

  ## Querying

      Reach.backward_slice(graph, node_id)
      Reach.forward_slice(graph, node_id)
      Reach.independent?(graph, id_a, id_b)
      Reach.nodes(graph, type: :call, module: Enum)
      Reach.data_flows?(graph, source_id, sink_id)

  ## Inspecting nodes

      node = Reach.node(graph, some_id)
      node.type       #=> :call
      node.meta       #=> %{module: Enum, function: :map, arity: 2}
      node.source_span #=> %{file: "lib/foo.ex", start_line: 5, ...}

      Reach.pure?(node)  #=> true
  """

  alias Reach.{Effects, Frontend, Query, SystemDependence}
  alias Reach.IR.Counter
  alias Reach.IR.Node

  @type graph :: SystemDependence.t()

  # --- Building ---

  @doc """
  Parses a source string and builds a program dependence graph.

  Returns `{:ok, graph}` or `{:error, reason}`.

  ## Options

    * `:language` — `:elixir` (default) or `:erlang`
    * `:file` — filename for source locations (default: `"nofile"`)
    * `:module` — module name for call graph resolution
  """
  @spec string_to_graph(String.t(), keyword()) :: {:ok, graph()} | {:error, term()}
  def string_to_graph(source, opts \\ []) do
    {language, opts} = Keyword.pop(opts, :language, :elixir)

    case parse_string(source, language, opts) do
      {:ok, ir_nodes} -> {:ok, SystemDependence.build(ir_nodes, opts)}
      {:error, _} = err -> err
    end
  end

  @doc """
  Same as `string_to_graph/2` but raises on parse error.
  """
  @spec string_to_graph!(String.t(), keyword()) :: graph()
  def string_to_graph!(source, opts \\ []) do
    case string_to_graph(source, opts) do
      {:ok, graph} -> graph
      {:error, reason} -> raise "Reach parse error: #{inspect(reason)}"
    end
  end

  @doc """
  Reads a source file and builds a program dependence graph.

  The language is auto-detected from the file extension (`.ex` / `.exs`
  for Elixir, `.erl` / `.hrl` for Erlang), or can be set explicitly
  via the `:language` option.

  Returns `{:ok, graph}` or `{:error, reason}`.
  """
  @spec file_to_graph(Path.t(), keyword()) :: {:ok, graph()} | {:error, term()}
  def file_to_graph(path, opts \\ []) do
    language = Keyword.get(opts, :language) || language_from_extension(path)
    opts = Keyword.put(opts, :language, language)

    case language do
      :erlang ->
        opts = Keyword.put_new(opts, :file, path)

        case Frontend.Erlang.parse_file(path, opts) do
          {:ok, nodes} -> {:ok, SystemDependence.build(nodes, opts)}
          {:error, _} = err -> err
        end

      _elixir ->
        case File.read(path) do
          {:ok, source} ->
            opts =
              opts
              |> Keyword.put_new(:file, path)
              |> Keyword.put_new(:module, module_from_path(path))

            parse_and_build(source, :elixir, opts)

          {:error, reason} ->
            {:error, {:file, reason}}
        end
    end
  end

  @doc """
  Same as `file_to_graph/2` but raises on error.
  """
  @spec file_to_graph!(Path.t(), keyword()) :: graph()
  def file_to_graph!(path, opts \\ []) do
    case file_to_graph(path, opts) do
      {:ok, graph} -> graph
      {:error, reason} -> raise "Reach error: #{inspect(reason)}"
    end
  end

  @doc """
  Builds a graph from a compiled module (loaded in the VM).

  Analyzes the macro-expanded Erlang abstract forms from the BEAM bytecode.
  This captures code injected by `use`, `defmacro`, and other macros that
  the source-level frontend misses.

  Requires the module to be compiled with debug info (the default).
  """
  @spec module_to_graph(module(), keyword()) :: {:ok, graph()} | {:error, term()}
  def module_to_graph(module, opts \\ []) do
    case Frontend.BEAM.from_module(module, opts) do
      {:ok, nodes} -> {:ok, SystemDependence.build(nodes, opts)}
      {:error, _} = err -> err
    end
  end

  @doc """
  Compiles an Elixir source string and builds a graph from the expanded bytecode.

  Unlike `string_to_graph/2`, this compiles the code first, so macro-expanded
  constructs (try/rescue inside macros, `use` callbacks, etc.) are visible.

  The source must define complete modules.
  """
  @spec compiled_to_graph(String.t() | [{module(), binary()}], keyword()) ::
          {:ok, graph()} | {:error, term()}
  def compiled_to_graph(source_or_modules, opts \\ [])

  def compiled_to_graph(source, opts) when is_binary(source) do
    case Frontend.BEAM.from_compiled_string(source, opts) do
      {:ok, nodes} -> {:ok, SystemDependence.build(nodes, opts)}
      {:error, _} = err -> err
    end
  end

  def compiled_to_graph(compiled, opts) when is_list(compiled) do
    case Frontend.BEAM.from_compiled_modules(compiled, opts) do
      {:ok, nodes} -> {:ok, SystemDependence.build(nodes, opts)}
    end
  end

  @doc """
  Builds a graph from an already-parsed Elixir AST.

  Useful when you already have the AST (e.g. from Credo or ExDNA)
  and don't want to re-parse source.
  """
  @spec ast_to_graph(Macro.t(), keyword()) :: {:ok, graph()} | {:error, term()}
  def ast_to_graph(ast, opts \\ []) do
    counter = Counter.new()
    file = Keyword.get(opts, :file, "nofile")
    nodes = Frontend.Elixir.translate_ast(ast, counter, file)
    {:ok, SystemDependence.build(List.wrap(nodes), opts)}
  end

  @doc """
  Returns the children of a block in canonical order.

  Independent sibling expressions are sorted by structural hash so
  that reordered-but-equivalent blocks produce the same sequence.
  Dependent expressions preserve their relative order.

  Returns a list of `{node_id, ir_node}` pairs.

  ## Example

      # These two blocks produce the same canonical order:
      #   a = 1; b = 2; c = a + b
      #   b = 2; a = 1; c = a + b
      # Because a=1 and b=2 are independent, they get sorted,
      # while c=a+b stays last (depends on both).
  """
  @spec canonical_order(graph(), Reach.IR.Node.id()) :: [{Reach.IR.Node.id(), Reach.IR.Node.t()}]
  def canonical_order(%SystemDependence{} = graph, block_node_id) do
    block = node(graph, block_node_id)

    case block do
      %{type: type, children: children} when type in [:block, :clause, :function_def] ->
        sort_preserving_deps(graph, children)

      _ ->
        case block do
          %{id: id} = n -> [{id, n}]
          nil -> []
        end
    end
  end

  defp sort_preserving_deps(graph, children) do
    indexed = Enum.with_index(children)

    # Build a dependency map: which children must come before which
    must_precede =
      for {a, i} <- indexed,
          {b, j} <- indexed,
          i < j,
          not independent?(graph, a.id, b.id),
          reduce: MapSet.new() do
        acc -> MapSet.put(acc, {i, j})
      end

    # Topological sort respecting dependencies, breaking ties by structural hash
    sorted_indices = topo_sort_with_hash(indexed, must_precede)

    Enum.map(sorted_indices, fn i ->
      {node, _} = Enum.at(indexed, i)
      {node.id, node}
    end)
  end

  defp topo_sort_with_hash(indexed, must_precede) do
    n = length(indexed)

    # Build adjacency + in-degree
    {adj, in_deg} =
      Enum.reduce(must_precede, {%{}, Map.new(0..(n - 1), &{&1, 0})}, fn {i, j}, {a, d} ->
        {Map.update(a, i, [j], &[j | &1]), Map.update(d, j, 1, &(&1 + 1))}
      end)

    # Compute structural hash for each child (for deterministic tie-breaking)
    hashes =
      Map.new(indexed, fn {node, i} ->
        {i, :erlang.phash2(node)}
      end)

    # Kahn's algorithm with hash-based priority
    ready =
      in_deg
      |> Enum.filter(fn {_, d} -> d == 0 end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort_by(&Map.get(hashes, &1))

    do_topo_sort(ready, adj, in_deg, hashes, [])
  end

  defp do_topo_sort([], _adj, _in_deg, _hashes, acc), do: Enum.reverse(acc)

  defp do_topo_sort([current | rest], adj, in_deg, hashes, acc) do
    neighbors = Map.get(adj, current, [])

    {new_ready, in_deg} =
      Enum.reduce(neighbors, {[], in_deg}, fn neighbor, {ready, deg} ->
        new_deg = Map.get(deg, neighbor, 0) - 1
        deg = Map.put(deg, neighbor, new_deg)
        if new_deg == 0, do: {[neighbor | ready], deg}, else: {ready, deg}
      end)

    next_ready =
      (rest ++ new_ready)
      |> Enum.sort_by(&Map.get(hashes, &1))

    do_topo_sort(next_ready, adj, in_deg, hashes, [current | acc])
  end

  # --- Slicing ---

  @doc """
  Returns all node IDs that affect the given node (backward slice).

  The backward slice answers: "what does this expression depend on?"
  """
  defdelegate backward_slice(graph, node_id), to: Reach.Graph

  @doc """
  Returns all node IDs affected by the given node (forward slice).

  The forward slice answers: "what does this expression influence?"
  """
  defdelegate forward_slice(graph, node_id), to: Reach.Graph

  @doc """
  Returns node IDs on all paths from `source` to `sink`.

  The chop answers: "how does A influence B?"
  """
  defdelegate chop(graph, source, sink), to: Reach.Graph

  # --- Independence ---

  @doc """
  Returns true if two expressions are independent.

  Two expressions are independent when:
  1. No data flows between them in either direction
  2. They execute under the same conditions (same control dependencies)
  3. Their side effects don't conflict

  Independent expressions can be safely reordered.
  """
  def independent?(graph, id_x, id_y) do
    Reach.Graph.independent?(to_graph(graph), id_x, id_y)
  end

  # --- Querying nodes ---

  @doc """
  Returns all IR nodes, optionally filtered.

  ## Options

    * `:type` — filter by node type (`:call`, `:match`, `:var`, etc.)
    * `:module` — filter calls by module
    * `:function` — filter calls by function name

  ## Examples

      Reach.nodes(graph, type: :call)
      Reach.nodes(graph, type: :call, module: Enum)
  """
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
    Reach.Graph.control_deps(to_graph(sdg), node_id)
  end

  @doc """
  Returns the data dependencies of a node.

  Each entry is `{source_node_id, variable_name}`.
  """
  @spec data_deps(graph(), Node.id()) :: [{Node.id(), atom()}]
  def data_deps(%SystemDependence{} = sdg, node_id) do
    Reach.Graph.data_deps(to_graph(sdg), node_id)
  end

  @doc """
  Returns the per-function PDG for a `{module, function, arity}` tuple.
  """
  @spec function_graph(graph(), SystemDependence.function_id()) :: Reach.Graph.t() | nil
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

  defp parse_string(source, :erlang, opts) do
    Frontend.Erlang.parse_string(source, opts)
  end

  defp parse_string(source, _elixir, opts) do
    Frontend.Elixir.parse(source, opts)
  end

  defp parse_and_build(source, language, opts) do
    case parse_string(source, language, opts) do
      {:ok, ir_nodes} -> {:ok, SystemDependence.build(ir_nodes, opts)}
      {:error, _} = err -> err
    end
  end

  defp language_from_extension(path) do
    case Path.extname(path) do
      ext when ext in [".erl", ".hrl"] -> :erlang
      _ -> :elixir
    end
  end

  defp to_graph(%SystemDependence{} = sdg) do
    %Reach.Graph{
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
