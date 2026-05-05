defmodule Mix.Tasks.Reach.Boundaries do
  @moduledoc """
  Removed compatibility task.

  Use `mix reach.map --boundaries` instead.
  """

  use Mix.Task

  alias Reach.CLI.Deprecation

  @dialyzer {:nowarn_function, run: 1}

  @shortdoc "Removed; use mix reach.map --boundaries"

  @impl Mix.Task
  def run(_args) do
    Deprecation.warn("reach.boundaries", "reach.map --boundaries")
  end
end
