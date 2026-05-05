defmodule Mix.Tasks.Reach.Graph do
  @moduledoc """
  Removed compatibility task.

  Use `mix reach.inspect TARGET --graph` instead.
  """

  use Mix.Task

  alias Reach.CLI.Deprecation

  @dialyzer {:nowarn_function, run: 1}

  @shortdoc "Removed; use mix reach.inspect TARGET --graph"

  @impl Mix.Task
  def run(_args) do
    Deprecation.warn("reach.graph TARGET", "reach.inspect TARGET --graph")
  end
end
