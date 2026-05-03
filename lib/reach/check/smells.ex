defmodule Reach.Check.Smells do
  @moduledoc """
  Runs structural and performance smell checks over a loaded project.
  """

  def run(project), do: Enum.flat_map(Reach.Smell.Registry.checks(), & &1.run(project))
  def analyze(project), do: run(project)
end
