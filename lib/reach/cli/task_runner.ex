defmodule Reach.CLI.TaskRunner do
  @moduledoc false

  alias Reach.CLI.Deprecation
  alias Reach.CLI.Format

  def run(task, args, opts \\ []) do
    Deprecation.delegated(fn ->
      with_command(opts[:command], fn ->
        Mix.Task.reenable(task)
        Mix.Task.run(task, args)
      end)
    end)
  end

  defp with_command(nil, fun), do: fun.()
  defp with_command(command, fun), do: Format.with_command(command, fun)
end
