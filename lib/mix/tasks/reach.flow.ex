defmodule Mix.Tasks.Reach.Flow do
  @moduledoc """
  Removed compatibility task.

  Use `mix reach.trace` instead.
  """

  use Mix.Task

  alias Reach.CLI.Deprecation

  @dialyzer {:nowarn_function, run: 1}

  @shortdoc "Removed; use mix reach.trace"

  @impl Mix.Task
  def run(_args) do
    Deprecation.warn("reach.flow", "reach.trace")
  end
end
