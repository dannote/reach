defmodule Mix.Tasks.Reach.Effects do
  @moduledoc """
  Compatibility wrapper for `mix reach.map --effects`.

  This task is kept for users upgrading from older Reach versions. New code and
  documentation should use the canonical dotted command:

      mix reach.map --effects

  """

  use Mix.Task

  @shortdoc "Show effect distribution"

  @impl Mix.Task
  def run(args) do
    Mix.Tasks.Reach.Map.run(["--effects" | args])
  end
end
