defmodule Mix.Tasks.Reach.Coupling do
  @moduledoc """
  Compatibility wrapper for `mix reach.map --coupling`.

  This task is kept for users upgrading from older Reach versions. New code and
  documentation should use the canonical dotted command:

      mix reach.map --coupling

  """

  use Mix.Task

  @shortdoc "Show module coupling"

  @impl Mix.Task
  def run(args) do
    Mix.Tasks.Reach.Map.run(["--coupling" | args])
  end
end
