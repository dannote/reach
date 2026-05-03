defmodule Mix.Tasks.Reach.DeadCode do
  @moduledoc """
  Removed compatibility task.

  Use `mix reach.check --dead-code` instead.
  """

  use Mix.Task

  alias Reach.CLI.Deprecation

  @dialyzer {:nowarn_function, run: 1}

  @shortdoc "Removed; use mix reach.check --dead-code"

  @impl Mix.Task
  def run(_args) do
    Deprecation.warn("reach.dead_code", "reach.check --dead-code")
  end
end
