defmodule Reach.CLI.Analyses.Smell.Helpers do
  @moduledoc false

  def function_defs(project) do
    project.nodes
    |> Map.values()
    |> Enum.filter(&(&1.type == :function_def))
  end
end
