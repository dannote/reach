defmodule Reach.IR.Helpers do
  @moduledoc false

  alias Reach.IR.Node

  def mark_as_definitions(%Node{type: :var, meta: meta} = node) do
    %{node | meta: Map.put(meta, :binding_role, :definition)}
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
end
