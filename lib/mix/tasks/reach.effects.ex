defmodule Mix.Tasks.Reach.Effects do
  @moduledoc """
  Removed compatibility task.

  Use `mix reach.map --effects` instead.
  """

  use Mix.Task

  alias Reach.CLI.Deprecation

  @dialyzer {:nowarn_function, run: 1}

  @shortdoc "Removed; use mix reach.map --effects"

  @impl Mix.Task
  def run(_args) do
    Deprecation.warn("reach.effects", "reach.map --effects")
  end
end
