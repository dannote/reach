defmodule Reach.IR do
  @moduledoc """
  Internal Representation for Reach.

  Provides functions for parsing source into IR and traversing IR node trees.
  """

  alias Reach.IR.Node

  @doc """
  Parses Elixir source code into IR nodes.
  """
  @spec from_string(String.t(), keyword()) :: {:ok, [Node.t()]} | {:error, term()}
  defdelegate from_string(source, opts \\ []), to: Reach.Frontend.Elixir, as: :parse

  @doc """
  Same as `from_string/2` but raises on error.
  """
  @spec from_string!(String.t(), keyword()) :: [Node.t()]
  defdelegate from_string!(source, opts \\ []), to: Reach.Frontend.Elixir, as: :parse!

  @doc """
  Collects all nodes in the IR tree (pre-order depth-first).
  """
  @spec all_nodes(Node.t() | [Node.t()]) :: [Node.t()]
  def all_nodes(nodes) when is_list(nodes) do
    Enum.flat_map(nodes, &all_nodes/1)
  end

  def all_nodes(%Node{children: children} = node) do
    [node | Enum.flat_map(children, &all_nodes/1)]
  end

  @doc """
  Finds all nodes of a given type.
  """
  @spec find_by_type([Node.t()] | Node.t(), Node.node_type()) :: [Node.t()]
  def find_by_type(nodes, type) do
    nodes |> all_nodes() |> Enum.filter(&(&1.type == type))
  end

  @doc """
  Finds a single node by ID.
  """
  @spec find_by_id([Node.t()] | Node.t(), Node.id()) :: Node.t() | nil
  def find_by_id(nodes, id) do
    nodes |> all_nodes() |> Enum.find(&(&1.id == id))
  end
end
