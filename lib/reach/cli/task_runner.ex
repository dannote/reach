defmodule Reach.CLI.TaskRunner do
  @moduledoc false

  alias Reach.CLI.Deprecation
  alias Reach.CLI.Format

  @analysis_tasks %{
    "reach.deps" => Reach.CLI.Analyses.Deps,
    "reach.impact" => Reach.CLI.Analyses.Impact,
    "reach.slice" => Reach.CLI.Analyses.Slice,
    "reach.flow" => Reach.CLI.Analyses.Flow,
    "reach.dead_code" => Reach.CLI.Analyses.DeadCode,
    "reach.smell" => Reach.CLI.Analyses.Smell,
    "reach.concurrency" => Reach.CLI.Analyses.Concurrency
  }

  def run(task, args, opts \\ []) do
    Deprecation.delegated(fn ->
      with_command(opts[:command], fn -> run_task(task, args) end)
    end)
  end

  defp run_task(task, args) do
    case Map.fetch(@analysis_tasks, task) do
      {:ok, module} -> module.run(args)
      :error -> run_mix_task(task, args)
    end
  end

  defp run_mix_task(task, args) do
    Mix.Task.reenable(task)
    Mix.Task.run(task, args)
  end

  defp with_command(nil, fun), do: fun.()
  defp with_command(command, fun), do: Format.with_command(command, fun)
end
