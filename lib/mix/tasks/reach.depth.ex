defmodule Mix.Tasks.Reach.Depth do
  @moduledoc """
  Removed compatibility task.

  Use `mix reach.map --depth` instead.
  """

  use Mix.Task

  alias Reach.CLI.Deprecation

  @dialyzer {:nowarn_function, run: 1}

  @shortdoc "Removed; use mix reach.map --depth"

  @impl Mix.Task
  def run(_args) do
    Deprecation.warn("reach.depth", "reach.map --depth")
  end
end
