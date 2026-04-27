defmodule Mix.Tasks.Reach.Deps do
  @moduledoc """
  Removed compatibility task.

  Use:

      mix reach.inspect TARGET --deps

  """

  use Mix.Task

  alias Reach.CLI.Deprecation

  @shortdoc "Removed: use mix reach.inspect TARGET --deps"

  @impl Mix.Task
  def run(_args) do
    Deprecation.warn("reach.deps TARGET", "reach.inspect TARGET --deps")
  end
end
