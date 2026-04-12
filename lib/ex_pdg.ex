defmodule ExPDG do
  @moduledoc """
  Program Dependence Graph for BEAM languages.

  ExPDG captures **what depends on what** in a program: which expressions
  produce values consumed by others (data dependence), and which expressions
  control whether others execute (control dependence).

  ## Quick start

      {:ok, graph} = ExPDG.Graph.from_string(\"""
      def example(x) do
        if x > 0 do
          x + 1
        else
          0
        end
      end
      \""")

      ExPDG.Graph.backward_slice(graph, node_id)
  """
end
