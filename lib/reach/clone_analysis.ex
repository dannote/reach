defmodule Reach.CloneAnalysis do
  @moduledoc false

  alias Reach.CloneAnalysis.ExDNA
  alias Reach.Config

  @cache_key {__MODULE__, :clones}

  def analyze(project, config \\ []) do
    config = Config.normalize(config).clone_analysis
    key = {project_fingerprint(project), config}

    case Process.get({@cache_key, key}) do
      nil ->
        clones = do_analyze(project, config)
        Process.put({@cache_key, key}, clones)
        clones

      clones ->
        clones
    end
  end

  defp do_analyze(project, config) do
    case config.provider do
      :ex_dna -> ExDNA.analyze(project, config)
      nil -> []
      false -> []
      _unknown -> []
    end
  end

  defp project_fingerprint(project) do
    project.nodes
    |> Map.keys()
    |> :erlang.phash2()
  end
end
