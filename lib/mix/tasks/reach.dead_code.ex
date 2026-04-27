defmodule Mix.Tasks.Reach.DeadCode do
  @moduledoc """
  Removed compatibility task.

  Use:

      mix reach.check --dead-code

  """

  use Mix.Task

  alias Reach.CLI.Deprecation

  @shortdoc "Removed: use mix reach.check --dead-code"

  @impl Mix.Task
  def run(_args) do
    Deprecation.warn("reach.dead_code", "reach.check --dead-code")
  end
end
