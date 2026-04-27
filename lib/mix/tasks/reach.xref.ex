defmodule Mix.Tasks.Reach.Xref do
  @moduledoc """
  Compatibility wrapper for `mix reach.map --data`.

  This task is kept for users upgrading from older Reach versions. New code and
  documentation should use the canonical dotted command:

      mix reach.map --data

  """

  use Mix.Task

  alias Reach.CLI.Deprecation

  @shortdoc "Deprecated: Show cross-function data flow"

  @impl Mix.Task
  def run(args) do
    Deprecation.warn("reach.xref", "reach.map --data")
    Mix.Tasks.Reach.Map.run(["--data" | args])
  end
end
