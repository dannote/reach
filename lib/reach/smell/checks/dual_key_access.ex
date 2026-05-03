defmodule Reach.Smell.Checks.DualKeyAccess do
  @moduledoc false

  use Reach.Smell.Check

  alias Reach.IR
  alias Reach.Smell.Finding

  defp findings(function) do
    function
    |> IR.all_nodes()
    |> Enum.flat_map(&key_access/1)
    |> Enum.group_by(fn access -> {access.variable, access.key} end)
    |> Enum.flat_map(fn {{variable, key}, accesses} ->
      key_types = accesses |> Enum.map(& &1.key_type) |> MapSet.new()

      if MapSet.subset?(MapSet.new([:atom, :string]), key_types) do
        [finding(variable, key, accesses)]
      else
        []
      end
    end)
  end

  defp key_access(%{type: :call, meta: %{module: module, function: :get, arity: arity}} = node)
       when module in [Access, Map] and arity in [2, 3] do
    case node.children do
      [%{type: :var, meta: %{name: variable}}, %{type: :literal, meta: %{value: key}} | _]
      when is_atom(key) or is_binary(key) ->
        [
          %{
            variable: variable,
            key: key_name(key),
            key_type: key_type(key),
            location: Helpers.location(node)
          }
        ]

      _ ->
        []
    end
  end

  defp key_access(_node), do: []

  defp finding(variable, key, accesses) do
    locations = accesses |> Enum.map(& &1.location) |> Enum.uniq()

    Finding.new(
      kind: :dual_key_access,
      message:
        "#{variable} is accessed with both atom and string key #{inspect(key)}; normalize the map once or use a struct/contract",
      location: List.first(locations),
      evidence: locations
    )
  end

  defp key_name(key) when is_binary(key), do: key
  defp key_name(key) when is_atom(key), do: Atom.to_string(key)

  defp key_type(key) when is_binary(key), do: :string
  defp key_type(key) when is_atom(key), do: :atom
end
