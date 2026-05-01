defmodule Reach.Test.ProgramFacts.Assertions do
  @moduledoc false

  import ExUnit.Assertions

  alias Mix.Tasks.Reach.Check, as: ReachCheck
  alias Reach.Test.ProgramFacts.{API, CLI, Normalize}

  def assert_modules_discovered(program) do
    expected = Normalize.modules(program.facts.modules)
    actual = API.modules(program)

    assert MapSet.subset?(expected, actual), "expected generated modules to be discovered"
  end

  def assert_call_edges_discovered(program) do
    expected = Normalize.call_edges(program.facts.call_edges)
    actual = API.call_edges(program)

    assert Enum.all?(expected, &edge_discovered?(&1, actual)),
           "expected generated call edges to be discovered"
  end

  def assert_effects_discovered(program) do
    expected = MapSet.new(program.facts.effects)
    actual = API.effects(program)

    assert MapSet.subset?(expected, actual), "expected generated effects to be discovered"
  end

  def assert_architecture_policy(program) do
    data = architecture_result(program)
    expected_type = expected_architecture_violation(program)

    if expected_type do
      assert data["status"] == "failed"
      assert Enum.any?(data["violations"], &(&1["type"] == expected_type))
    else
      assert data["status"] == "ok"
      assert data["violations"] == []
    end
  end

  defp architecture_result(program) do
    if expected_architecture_violation(program) do
      CLI.run_json_expect_raise(
        program,
        ReachCheck,
        ["--arch"],
        Mix.Error,
        ~r/Architecture policy failed/
      )
    else
      CLI.run_json(program, ReachCheck, ["--arch"])
    end
  end

  defp expected_architecture_violation(program) do
    case program.metadata.policy do
      :layered_valid -> nil
      :forbidden_dependency -> "forbidden_dependency"
      :layer_cycle -> "layer_cycle"
      :public_api_boundary_violation -> "public_api_boundary"
      :internal_boundary_violation -> "internal_boundary"
      :allowed_effect_violation -> "effect_policy"
    end
  end

  defp edge_discovered?({expected_source, expected_target}, actual_edges) do
    Enum.any?(actual_edges, fn {actual_source, actual_target} ->
      function_match?(expected_source, actual_source) and
        function_match?(expected_target, actual_target)
    end)
  end

  defp function_match?(
         {expected_module, expected_function, expected_arity},
         {actual_module, actual_function, actual_arity}
       ) do
    expected_function == actual_function and expected_arity == actual_arity and
      (actual_module == nil or actual_module == expected_module)
  end
end
