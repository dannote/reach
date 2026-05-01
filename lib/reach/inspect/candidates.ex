defmodule Reach.Inspect.Candidates do
  @moduledoc """
  Finds advisory graph-backed refactoring candidates for one target function.
  """

  alias Reach.Analysis
  alias Reach.CLI.Project
  alias Reach.Effects
  alias Reach.IR

  def find(project, mfa, func) do
    non_pure_effects = function_effect_atoms(func) -- [:pure, :unknown, :exception]
    callers = Project.callers(project, mfa, 1)
    branch_count = branch_count(func)

    []
    |> maybe_candidate(isolate_effects_candidate(func, non_pure_effects))
    |> maybe_candidate(extract_region_candidate(func, branch_count, callers))
  end

  defp isolate_effects_candidate(func, effects) do
    cond do
      length(effects) < 2 ->
        nil

      Analysis.expected_effect_boundary?(func) ->
        nil

      true ->
        %{
          id: "R2-001",
          kind: "isolate_effects",
          file: func.source_span && func.source_span.file,
          line: func.source_span && func.source_span.start_line,
          benefit: :medium,
          risk: :medium,
          confidence: :medium,
          actionability: :review_effect_order,
          evidence: ["mixed_effects"],
          effects: Enum.map(effects, &to_string/1),
          proof: [
            "Preserve side-effect order exactly.",
            "Extract only pure decision/preparation code first.",
            "Run tests covering both success and error paths."
          ],
          suggestion:
            "Split pure decision logic from side-effect execution while preserving effect order."
        }
    end
  end

  defp extract_region_candidate(_func, branch_count, _callers) when branch_count < 4,
    do: nil

  defp extract_region_candidate(func, branch_count, callers) do
    %{
      id: "R1-001",
      kind: "extract_pure_region",
      file: func.source_span && func.source_span.file,
      line: func.source_span && func.source_span.start_line,
      benefit: :medium,
      risk: if(length(callers) > 3, do: :high, else: :medium),
      confidence: :medium,
      actionability: :needs_region_proof,
      evidence: ["branchy_function", "caller_impact"],
      branches: branch_count,
      direct_caller_count: length(callers),
      proof: [
        "Identify a single-entry/single-exit region before editing.",
        "Verify extracted region has explicit inputs and one clear output.",
        "Add or run fixture tests around behavior and source spans."
      ],
      suggestion:
        "Look for a single-entry/single-exit pure branch region before extracting. Do not extract by size alone."
    }
  end

  defp maybe_candidate(candidates, nil), do: candidates
  defp maybe_candidate(candidates, candidate), do: candidates ++ [candidate]

  defp branch_count(func) do
    func
    |> IR.all_nodes()
    |> Enum.count(
      &(&1.type in [:case, :receive, :try] or
          (&1.type == :binary_op and &1.meta[:operator] in [:and, :or, :&&, :||]))
    )
  end

  defp function_effect_atoms(func) do
    func
    |> IR.all_nodes()
    |> Enum.map(&Effects.classify/1)
    |> Enum.uniq()
    |> Enum.sort()
  end
end
