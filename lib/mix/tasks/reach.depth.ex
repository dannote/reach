defmodule Mix.Tasks.Reach.Depth do
  @moduledoc """
  Compatibility wrapper for `mix reach.map --depth`.

  This task is kept for users upgrading from older Reach versions. New code and
  documentation should use the canonical dotted command:

      mix reach.map --depth

  """

  use Mix.Task

  @shortdoc "Show control depth"

  @impl Mix.Task
  def run(args) do
    Mix.Tasks.Reach.Map.run(["--depth" | args])
  end
end
