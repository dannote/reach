defmodule Mix.Tasks.Reach.Coupling do
  @moduledoc """
  Compatibility wrapper for `mix reach.map --coupling`.

  This task is kept for users upgrading from older Reach versions. New code and
  documentation should use the canonical dotted command:

      mix reach.map --coupling

  """

  use Mix.Task

  alias Reach.CLI.{Deprecation, Pipe}

  @shortdoc "Deprecated: Show module coupling"

  @impl Mix.Task
  def run(args) do
    Pipe.safely(fn ->
      Deprecation.warn("reach.coupling", "reach.map --coupling")
      Mix.Tasks.Reach.Map.run(["--coupling" | args])
    end)
  end
end
