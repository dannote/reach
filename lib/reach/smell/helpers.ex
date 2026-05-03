defmodule Reach.Smell.Helpers do
  @moduledoc false

  alias Reach.IR.Helpers, as: IRHelpers

  def function_defs(project) do
    project.nodes
    |> Map.values()
    |> Enum.filter(&(&1.type == :function_def))
  end

  def location(node) do
    case node.source_span do
      %{file: file, start_line: line} -> "#{file}:#{line}"
      _ -> "unknown"
    end
  end

  def call_name(node), do: IRHelpers.call_name(node)
end
