defmodule Reach.Smell.Registry do
  @moduledoc false

  alias Reach.Smell.Check

  def checks do
    :reach
    |> Application.spec(:modules)
    |> List.wrap()
    |> Enum.filter(&check?/1)
    |> Enum.sort()
  end

  defp check?(module) do
    Code.ensure_loaded?(module) and Check in behaviours(module)
  end

  defp behaviours(module) do
    module.module_info(:attributes)
    |> Keyword.get_values(:behaviour)
    |> List.flatten()
  end
end
