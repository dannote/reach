defmodule Reach.IR.Helpers do
  @moduledoc false

  alias Reach.IR.Node

  def mark_as_definitions(%Node{type: :var, meta: meta} = node) do
    %{node | meta: Map.put(meta, :binding_role, :definition)}
  end

  def mark_as_definitions(%Node{type: :call, meta: %{function: f}} = node)
      when f in [:unquote, :unquote_splicing] do
    node
  end

  def mark_as_definitions(%Node{children: children} = node) do
    %{node | children: Enum.map(children, &mark_as_definitions/1)}
  end

  def mark_as_definitions(other), do: other

  def param_var_name(%Node{type: :var, meta: %{name: name}}), do: name
  def param_var_name(_), do: nil

  def var_used_in_subtree?(%Node{type: :var, meta: %{name: name}}, target), do: name == target

  def var_used_in_subtree?(%Node{children: children}, target) do
    Enum.any?(children, &var_used_in_subtree?(&1, target))
  end

  def language_from_path(path) do
    case Path.extname(path) do
      ext when ext in [".erl", ".hrl"] -> :erlang
      ".gleam" -> :gleam
      _ -> :elixir
    end
  end

  def module_from_path(path) do
    path
    |> Path.rootname()
    |> Path.split()
    |> Enum.drop_while(&(&1 != "lib" and &1 != "src"))
    |> Enum.drop(1)
    |> Enum.map_join(".", &Macro.camelize/1)
    |> then(fn
      "" -> nil
      name -> Module.concat([name])
    end)
  end

  def clause_labels(func_def) do
    func_def.children
    |> Enum.filter(&(&1.type == :clause))
    |> Enum.map(fn clause ->
      clause.children
      |> Enum.take_while(fn c -> c.type not in [:guard, :block] end)
      |> List.first()
      |> clause_label()
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp clause_label(nil), do: nil
  defp clause_label(%Node{type: :literal, meta: %{value: v}}) when is_binary(v), do: v
  defp clause_label(%Node{type: :literal, meta: %{value: v}}) when is_atom(v), do: inspect(v)

  defp clause_label(%Node{type: :tuple, children: [%Node{type: :literal, meta: %{value: v}} | _]})
       when is_atom(v),
       do: inspect(v)

  defp clause_label(%Node{type: :var, meta: %{name: name}}), do: to_string(name)
  defp clause_label(%Node{type: :match, children: [pattern | _]}), do: clause_label(pattern)
  defp clause_label(_), do: nil
end
