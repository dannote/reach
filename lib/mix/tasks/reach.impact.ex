defmodule Mix.Tasks.Reach.Impact do
  @moduledoc """
  Removed compatibility task.

  Use:

      mix reach.inspect TARGET --impact

  """

  use Mix.Task

  alias Reach.CLI.{Deprecation, Pipe}

  @shortdoc "Removed: use mix reach.inspect TARGET --impact"

  @impl Mix.Task
  def run(_args) do
    Pipe.safely(fn ->
      Deprecation.warn("reach.impact TARGET", "reach.inspect TARGET --impact")
    end)
  end
end
