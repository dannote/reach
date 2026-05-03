defmodule Reach.CloneAnalysis do
  @moduledoc false

  alias Reach.CloneAnalysis.ExDNA
  alias Reach.Config

  def analyze(project, config \\ []) do
    config = Config.normalize(config).clone_analysis

    case config.provider do
      :ex_dna -> ExDNA.analyze(project, config)
      nil -> []
      false -> []
      _unknown -> []
    end
  end
end
