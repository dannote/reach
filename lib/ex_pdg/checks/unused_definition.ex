defmodule ExPDG.Checks.UnusedDefinition do
  @moduledoc """
  Detects variables that are defined but never referenced later.

  Only flags match expressions in blocks where the defined variable
  name doesn't appear anywhere else in the same function. Very
  conservative to minimize false positives.
  """

  @behaviour ExPDG.Check

  @impl true
  def meta, do: %{severity: :warning, category: :code_quality}

  @impl true
  def run(graph, _opts) do
    import ExPDG.Query

    all = nodes(graph)

    func_defs = Enum.filter(all, &(&1.type == :function_def))

    Enum.flat_map(func_defs, fn func_def ->
      check_function(func_def)
    end)
  end

  defp check_function(func_def) do
    all_in_func = ExPDG.IR.all_nodes(func_def)

    all_var_uses =
      all_in_func
      |> Enum.filter(&(&1.type == :var))
      |> Enum.map(& &1.meta[:name])
      |> Enum.frequencies()

    matches =
      Enum.filter(all_in_func, fn node ->
        node.type == :match and
          hd(node.children).type == :var
      end)

    for match_node <- matches,
        var_node = hd(match_node.children),
        var_name = var_node.meta[:name],
        var_name != :_,
        not String.starts_with?(Atom.to_string(var_name), "_"),
        Map.get(all_var_uses, var_name, 0) <= 1 do
      %ExPDG.Diagnostic{
        check: :unused_definition,
        severity: :warning,
        category: :code_quality,
        message: "Variable `#{var_name}` is defined but never used",
        location: match_node.source_span,
        node_id: match_node.id
      }
    end
  end
end
