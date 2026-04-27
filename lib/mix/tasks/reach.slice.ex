defmodule Mix.Tasks.Reach.Slice do
  @moduledoc """
  Removed compatibility task.

  Use:

      mix reach.trace TARGET

  """

  use Mix.Task

  alias Reach.CLI.Deprecation

  @shortdoc "Removed: use mix reach.trace TARGET"

  @impl Mix.Task
  def run(_args) do
    Deprecation.warn("reach.slice TARGET", "reach.trace TARGET")
  end
end
