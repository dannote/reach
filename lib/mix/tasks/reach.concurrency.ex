defmodule Mix.Tasks.Reach.Concurrency do
  @moduledoc """
  Removed compatibility task.

  Use `mix reach.otp --concurrency` instead.
  """

  use Mix.Task

  alias Reach.CLI.Deprecation

  @dialyzer {:nowarn_function, run: 1}

  @shortdoc "Removed; use mix reach.otp --concurrency"

  @impl Mix.Task
  def run(_args) do
    Deprecation.warn("reach.concurrency", "reach.otp --concurrency")
  end
end
