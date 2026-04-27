defmodule Mix.Tasks.Reach.Hotspots do
  @moduledoc """
  Compatibility wrapper for `mix reach.map --hotspots`.

  This task is kept for users upgrading from older Reach versions. New code and
  documentation should use the canonical dotted command:

      mix reach.map --hotspots

  """

  use Mix.Task

  @shortdoc "Show hotspots"

  @impl Mix.Task
  def run(args) do
    Mix.Tasks.Reach.Map.run(["--hotspots" | args])
  end
end
