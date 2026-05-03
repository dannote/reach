defmodule Mix.Tasks.Reach.Hotspots do
  @moduledoc """
  Removed compatibility task.

  Use `mix reach.map --hotspots` instead.
  """

  use Mix.Task

  alias Reach.CLI.Deprecation

  @dialyzer {:nowarn_function, run: 1}

  @shortdoc "Removed; use mix reach.map --hotspots"

  @impl Mix.Task
  def run(_args) do
    Deprecation.warn("reach.hotspots", "reach.map --hotspots")
  end
end
