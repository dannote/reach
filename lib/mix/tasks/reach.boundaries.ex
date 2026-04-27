defmodule Mix.Tasks.Reach.Boundaries do
  @moduledoc """
  Compatibility wrapper for `mix reach.map --boundaries`.

  This task is kept for users upgrading from older Reach versions. New code and
  documentation should use the canonical dotted command:

      mix reach.map --boundaries

  """

  use Mix.Task

  @shortdoc "Show effect boundaries"

  @impl Mix.Task
  def run(args) do
    Mix.Tasks.Reach.Map.run(["--boundaries" | args])
  end
end
