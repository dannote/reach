defmodule Reach.Smell.Checks.BehaviourCandidate do
  @moduledoc false

  @behaviour Reach.Smell.Check

  alias Reach.IR
  alias Reach.Smell.Finding
  alias Reach.Smell.Helpers

  @min_modules 3
  @min_callbacks 3
  @module_display_limit 8
  @callback_display_limit 8

  @impl true
  def run(project) do
    project
    |> module_public_apis()
    |> Enum.group_by(& &1.signature)
    |> Enum.flat_map(&behaviour_candidate/1)
  end

  defp module_public_apis(project) do
    project.nodes
    |> Map.values()
    |> Enum.filter(&(&1.type == :module_def and &1.source_span))
    |> Enum.flat_map(&module_public_api/1)
  end

  defp module_public_api(module) do
    callbacks =
      module
      |> IR.all_nodes()
      |> Enum.filter(&public_function?/1)
      |> Enum.map(&function_signature/1)
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.reject(&ignored_callback?/1)

    if length(callbacks) >= @min_callbacks do
      [
        %{
          module: inspect(module.meta[:name]),
          location: Helpers.location(module),
          signature: callbacks
        }
      ]
    else
      []
    end
  end

  defp public_function?(%{type: :function_def, meta: %{kind: kind}})
       when kind in [:def, :defmacro],
       do: true

  defp public_function?(_node), do: false

  defp function_signature(function), do: {function.meta[:name], function.meta[:arity]}

  defp ignored_callback?({name, _arity}) do
    name in [:__struct__, :child_spec, :module_info]
  end

  defp behaviour_candidate({callbacks, modules}) do
    distinct_modules = Enum.uniq_by(modules, & &1.module)

    if length(distinct_modules) >= @min_modules do
      sorted_modules = Enum.sort_by(distinct_modules, & &1.module)
      callback_names = Enum.map(callbacks, &format_callback/1)
      module_names = Enum.map(sorted_modules, & &1.module)

      [
        Finding.new(
          kind: :behaviour_candidate,
          message:
            "#{length(sorted_modules)} modules expose the same #{length(callbacks)} public callbacks; consider extracting a behaviour if these modules are interchangeable implementations",
          location: List.first(sorted_modules).location,
          evidence: Enum.map(sorted_modules, & &1.location),
          modules: Enum.take(module_names, @module_display_limit),
          callbacks: Enum.take(callback_names, @callback_display_limit),
          occurrences: length(sorted_modules)
        )
      ]
    else
      []
    end
  end

  defp format_callback({name, arity}), do: "#{name}/#{arity}"
end
