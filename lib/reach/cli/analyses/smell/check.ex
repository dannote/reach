defmodule Reach.CLI.Analyses.Smell.Check do
  @moduledoc false

  @callback run(Reach.Project.t()) :: [map()]

  defmacro __using__(_opts) do
    quote do
      @behaviour Reach.CLI.Analyses.Smell.Check

      alias Reach.CLI.Analyses.Smell.Helpers

      def run(project) do
        project
        |> Helpers.function_defs()
        |> Enum.flat_map(&findings/1)
      end
    end
  end
end
