defmodule Mix.Tasks.Reach.Smell do
  @moduledoc """
  Removed compatibility task.

  Use `mix reach.check --smells` instead.
  """

  use Mix.Task

  alias Reach.CLI.Deprecation

  @dialyzer {:nowarn_function, run: 1}

  @shortdoc "Removed; use mix reach.check --smells"

  @impl Mix.Task
  def run(_args) do
    Deprecation.warn("reach.smell", "reach.check --smells")
  end
end
