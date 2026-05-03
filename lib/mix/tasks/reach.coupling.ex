defmodule Mix.Tasks.Reach.Coupling do
  @moduledoc """
  Removed compatibility task.

  Use `mix reach.map --coupling` instead.
  """

  use Mix.Task

  alias Reach.CLI.Deprecation

  @dialyzer {:nowarn_function, run: 1}

  @shortdoc "Removed; use mix reach.map --coupling"

  @impl Mix.Task
  def run(_args) do
    Deprecation.warn("reach.coupling", "reach.map --coupling")
  end
end
