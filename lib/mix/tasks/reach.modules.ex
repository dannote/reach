defmodule Mix.Tasks.Reach.Modules do
  @moduledoc """
  Compatibility wrapper for `mix reach.map --modules`.

  This task is kept for users upgrading from older Reach versions. New code and
  documentation should use the canonical dotted command:

      mix reach.map --modules

  """

  use Mix.Task

  alias Reach.CLI.{Deprecation, Pipe}

  @shortdoc "Deprecated: List modules"

  @impl Mix.Task
  def run(args) do
    Pipe.safely(fn ->
      Deprecation.warn("reach.modules", "reach.map --modules")
      Mix.Tasks.Reach.Map.run(["--modules" | args])
    end)
  end
end
