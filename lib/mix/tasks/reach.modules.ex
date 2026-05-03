defmodule Mix.Tasks.Reach.Modules do
  @moduledoc """
  Removed compatibility task.

  Use `mix reach.map --modules` instead.
  """

  use Mix.Task

  alias Reach.CLI.Deprecation

  @dialyzer {:nowarn_function, run: 1}

  @shortdoc "Removed; use mix reach.map --modules"

  @impl Mix.Task
  def run(_args) do
    Deprecation.warn("reach.modules", "reach.map --modules")
  end
end
