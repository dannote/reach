defmodule Reach.CLI.Analyses.Smell.Check do
  @moduledoc false

  @callback run(Reach.Project.t()) :: [map()]
end
