defmodule Reach.IR do
  @moduledoc """
  Internal Representation tree utilities.

  Provides functions for traversing and querying IR node trees.
  To build IR from source, use `Reach.string_to_graph/2` or
  `Reach.file_to_graph/2`.
  """

  alias Reach.IR.Node

  @doc false
  @spec from_string(String.t(), keyword()) :: {:ok, [Node.t()]} | {:error, term()}
  defdelegate from_string(source, opts \\ []), to: Reach.Frontend.Elixir, as: :parse

  @doc false
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
end
