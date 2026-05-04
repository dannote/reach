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

  @elixir_extensions [".ex", ".exs"]
  @erlang_extensions [".erl", ".hrl"]
  @javascript_extensions [".js", ".ts", ".tsx", ".jsx", ".mjs"]
  @gleam_extensions [".gleam"]

  def elixir_extensions, do: @elixir_extensions
  def erlang_extensions, do: @erlang_extensions
  def javascript_extensions, do: @javascript_extensions

  def source_extensions,
    do: @elixir_extensions ++ @erlang_extensions ++ @gleam_extensions ++ @javascript_extensions

  def language_from_path(path) do
    case Path.extname(path) do
      ext when ext in @erlang_extensions -> :erlang
      ext when ext in @gleam_extensions -> :gleam
      ext when ext in @javascript_extensions -> :javascript
      _ -> :elixir
    end
  end

  def location(%Node{} = node) do
    case node.source_span do
      %{file: file, start_line: line} -> "#{file}:#{line}"
      _ -> "unknown"
    end
  end

  def call_name(%Node{} = node) do
    mod = node.meta[:module]
    fun = node.meta[:function]
    if mod, do: "#{inspect(mod)}.#{fun}", else: to_string(fun)
  end

  def func_id_to_string({mod, fun, arity}) when is_atom(mod) and mod != nil do
    "#{inspect(mod)}.#{fun}/#{arity}"
  end

  def func_id_to_string({nil, fun, arity}), do: "#{fun}/#{arity}"
  def func_id_to_string(other), do: inspect(other)

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
