defmodule Reach.Smell.Check do
  @moduledoc false

  @callback run(Reach.Project.t()) :: [map()]

  defmacro __using__(_opts) do
    quote do
      @behaviour Reach.Smell.Check

      alias Reach.Smell.Helpers

      def run(project) do
        project
        |> Helpers.function_defs()
        |> Enum.flat_map(&findings/1)
      end
    end
  end
end
