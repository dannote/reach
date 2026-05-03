defmodule Mix.Tasks.Reach.Xref do
  @moduledoc """
  Removed compatibility task.

  Use `mix reach.map --data` instead.
  """

  use Mix.Task

  alias Reach.CLI.Deprecation

  @dialyzer {:nowarn_function, run: 1}

  @shortdoc "Removed; use mix reach.map --data"

  @impl Mix.Task
  def run(_args) do
    Deprecation.warn("reach.xref", "reach.map --data")
  end
end
