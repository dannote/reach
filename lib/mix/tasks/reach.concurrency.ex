defmodule Mix.Tasks.Reach.Concurrency do
  @moduledoc """
  Removed compatibility task.

  Use:

      mix reach.otp --concurrency

  """

  use Mix.Task

  alias Reach.CLI.{Deprecation, Pipe}

  @shortdoc "Removed: use mix reach.otp --concurrency"

  @impl Mix.Task
  def run(_args) do
    Pipe.safely(fn ->
      Deprecation.warn("reach.concurrency", "reach.otp --concurrency")
    end)
  end
end
