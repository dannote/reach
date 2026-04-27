defmodule Mix.Tasks.Reach.Concurrency do
  @moduledoc """
  Removed compatibility task.

  Use:

      mix reach.otp --concurrency

  """

  use Mix.Task

  alias Reach.CLI.Deprecation

  @shortdoc "Removed: use mix reach.otp --concurrency"

  @impl Mix.Task
  def run(_args) do
    Deprecation.warn("reach.concurrency", "reach.otp --concurrency")
  end
end
