defmodule Reach.CLI.Analyses.Smell.ReverseAppend do
  @moduledoc false

  use Reach.CLI.Analyses.Smell.Check

  alias Reach.CLI.Analyses.Smell.Finding
  alias Reach.CLI.Format
  alias Reach.IR

  defp findings(func) do
    func
    |> IR.all_nodes()
    |> Enum.filter(&reverse_append?/1)
    |> Enum.map(fn node ->
      Finding.new(
        kind: :suboptimal,
        message: "Enum.reverse(list) ++ tail traverses twice. Use Enum.reverse(list, tail)",
        location: Format.location(node)
      )
    end)
  end

  defp reverse_append?(%{
         type: :binary_op,
         meta: %{operator: :++},
         children: [%{type: :call, meta: %{module: Enum, function: :reverse, arity: 1}}, _tail],
         source_span: source_span
       })
       when not is_nil(source_span),
       do: true

  defp reverse_append?(_node), do: false
end
