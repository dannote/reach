defmodule Mix.Tasks.Reach.Impact do
  @moduledoc """
  Removed compatibility task.

  Use `mix reach.inspect TARGET --impact` instead.
  """

  use Mix.Task

  alias Reach.CLI.Deprecation

  @dialyzer {:nowarn_function, run: 1}

  @shortdoc "Removed; use mix reach.inspect TARGET --impact"

  @impl Mix.Task
  def run(_args) do
    Deprecation.warn("reach.impact TARGET", "reach.inspect TARGET --impact")
  end
end
