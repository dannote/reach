defmodule Reach.Check.Smells do
  @moduledoc """
  Runs structural and performance smell checks over a loaded project.
  """

  alias Reach.Config

  def run(project, config \\ []) do
    smell_config = Config.normalize(config).smells
    Enum.flat_map(Reach.Smell.Registry.checks(), &run_check(&1, project, smell_config))
  end

  def analyze(project), do: run(project)

  defp run_check(check, project, config) do
    if function_exported?(check, :run, 2),
      do: check.run(project, config),
      else: check.run(project)
  end
end
