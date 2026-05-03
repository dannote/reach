defmodule Reach.CloneAnalysis.ExDNA do
  @moduledoc false

  alias Reach.CloneAnalysis.{Clone, Fragment}
  alias Reach.Effects
  alias Reach.IR
  alias Reach.Project.Query

  def analyze(project, config) do
    if available?() do
      project
      |> source_paths()
      |> run_ex_dna(config)
      |> Enum.map(&to_clone(&1, project))
      |> Enum.reject(&(&1.fragments == []))
      |> Enum.take(config.max_clones)
    else
      []
    end
  end

  def available? do
    Code.ensure_loaded?(Module.concat([ExDNA]))
  end

  defp source_paths(project) do
    project.nodes
    |> Map.values()
    |> Enum.flat_map(fn node ->
      case node.source_span do
        %{file: file} when is_binary(file) -> [file]
        _ -> []
      end
    end)
    |> Enum.uniq()
    |> Enum.filter(&File.regular?/1)
  end

  defp run_ex_dna([], _config), do: []

  defp run_ex_dna(paths, config) do
    ex_dna = Module.concat([ExDNA])

    report =
      ex_dna.analyze(
        paths: paths,
        min_mass: config.min_mass,
        min_similarity: config.min_similarity,
        reporters: []
      )

    report.clones
  rescue
    _ -> []
  end

  defp to_clone(ex_dna_clone, project) do
    Clone.new(
      type: Map.get(ex_dna_clone, :type),
      mass: Map.get(ex_dna_clone, :mass),
      similarity: Map.get(ex_dna_clone, :similarity),
      fragments: Enum.map(Map.get(ex_dna_clone, :fragments, []), &fragment(&1, project)),
      suggestion: Map.get(ex_dna_clone, :suggestion)
    )
  end

  defp fragment(ex_dna_fragment, project) do
    file = Map.get(ex_dna_fragment, :file)
    line = Map.get(ex_dna_fragment, :line)
    function = if file && line, do: Query.find_function_at_location(project, file, line)

    Fragment.new(
      file: file,
      line: line,
      module: function && function.meta[:module],
      function: function && function.meta[:name],
      arity: function && function.meta[:arity],
      effects: function_effects(function),
      mass: Map.get(ex_dna_fragment, :mass)
    )
  end

  defp function_effects(nil), do: []

  defp function_effects(function) do
    function
    |> IR.all_nodes()
    |> Enum.map(&Effects.classify/1)
    |> Enum.uniq()
    |> Enum.sort()
  end
end
