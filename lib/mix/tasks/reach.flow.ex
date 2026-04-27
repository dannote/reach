defmodule Mix.Tasks.Reach.Flow do
  @moduledoc """
  Removed compatibility task.

  Use:

      mix reach.trace

  """

  use Mix.Task

  alias Reach.CLI.Deprecation

  @shortdoc "Removed: use mix reach.trace"

  @impl Mix.Task
  def run(_args) do
    Deprecation.warn("reach.flow", "reach.trace")
  end
end
