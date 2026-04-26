defmodule Reach.CLI.TaskRunner do
  @moduledoc false

  def run(task, args) do
    Mix.Task.reenable(task)
    Mix.Task.run(task, args)
  end
end
