defmodule Reach.Smell.Checks.ConfigPhase do
  @moduledoc false

  @behaviour Reach.Smell.Check

  alias Reach.IR
  alias Reach.Smell.Finding
  alias Reach.Smell.Helpers

  @runtime_env_functions [:get_env, :fetch_env, :fetch_env!]
  @compile_env_functions [:compile_env, :compile_env!]

  @impl true
  def run(project) do
    project.nodes
    |> Map.values()
    |> Enum.filter(&(&1.type == :module_def))
    |> Enum.flat_map(&module_findings/1)
  end

  defp module_findings(module) do
    runtime_env_module_attributes(module) ++ compile_env_function_calls(module)
  end

  defp runtime_env_module_attributes(module) do
    module
    |> module_body_nodes()
    |> Enum.filter(&module_attribute?/1)
    |> Enum.flat_map(fn attribute ->
      attribute
      |> IR.all_nodes()
      |> Enum.filter(&application_env_call?(&1, @runtime_env_functions))
      |> Enum.map(&runtime_env_attribute_finding(attribute, &1))
    end)
  end

  defp compile_env_function_calls(module) do
    module
    |> IR.all_nodes()
    |> Enum.filter(&(&1.type == :function_def))
    |> Enum.flat_map(fn function ->
      function
      |> IR.all_nodes()
      |> Enum.filter(&application_env_call?(&1, @compile_env_functions))
      |> Enum.map(&compile_env_function_finding/1)
    end)
  end

  defp module_body_nodes(%{children: [%{type: :block, children: children}]}), do: children
  defp module_body_nodes(%{children: children}), do: children

  defp module_attribute?(%{type: :call, meta: %{function: :@, arity: 1}}), do: true
  defp module_attribute?(_node), do: false

  defp application_env_call?(
         %{type: :call, meta: %{module: Application, function: function}},
         functions
       ),
       do: function in functions

  defp application_env_call?(_node, _functions), do: false

  defp runtime_env_attribute_finding(attribute, env_call) do
    Finding.new(
      kind: :config_phase,
      message:
        "module attribute stores Application.#{env_call.meta.function}/#{env_call.meta.arity} at compile time; use Application.compile_env for compile-time config or read Application env inside a function for runtime config",
      location: Helpers.location(attribute),
      evidence: [Helpers.location(env_call)]
    )
  end

  defp compile_env_function_finding(env_call) do
    Finding.new(
      kind: :config_phase,
      message:
        "Application.#{env_call.meta.function}/#{env_call.meta.arity} inside a function is still compile-time config; use Application.get_env/fetch_env when the value must change at runtime",
      location: Helpers.location(env_call)
    )
  end
end
