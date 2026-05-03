defmodule Mix.Tasks.Reach.Deps do
  @moduledoc """
  Removed compatibility task.

  Use:

      mix reach.inspect TARGET --deps

  """

  use Mix.Task

  alias Reach.CLI.{Deprecation, Pipe}

  @shortdoc "Removed: use mix reach.inspect TARGET --deps"

  @impl Mix.Task
  def run(_args) do
    Pipe.safely(fn ->
      Deprecation.warn("reach.deps TARGET", "reach.inspect TARGET --deps")
    end)
  end
end
