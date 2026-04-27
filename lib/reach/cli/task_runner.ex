defmodule Reach.CLI.TaskRunner do
  @moduledoc false

  alias Reach.CLI.Deprecation

  def run(task, args) do
    Deprecation.delegated(fn ->
      Mix.Task.reenable(task)
      Mix.Task.run(task, args)
    end)
  end
end
