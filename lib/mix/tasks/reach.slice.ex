defmodule Mix.Tasks.Reach.Slice do
  @moduledoc """
  Removed compatibility task.

  Use:

      mix reach.trace TARGET

  """

  use Mix.Task

  alias Reach.CLI.{Deprecation, Pipe}

  @shortdoc "Removed: use mix reach.trace TARGET"

  @impl Mix.Task
  def run(_args) do
    Pipe.safely(fn ->
      Deprecation.warn("reach.slice TARGET", "reach.trace TARGET")
    end)
  end
end
