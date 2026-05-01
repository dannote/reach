defmodule Reach.Test.ProgramFacts.Assertions do
  @moduledoc false

  import ExUnit.Assertions

  alias Reach.Test.ProgramFacts.{API, Normalize}

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
