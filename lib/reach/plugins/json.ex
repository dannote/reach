defmodule Reach.Plugins.JSON do
  @moduledoc false
  @behaviour Reach.Plugin

  alias Reach.IR.Node

  @json_modules [Jason, Poison]

  @impl true
  def classify_effect(%Node{type: :call, meta: %{module: mod}})
      when mod in @json_modules,
      do: :pure

  def classify_effect(_), do: nil

  @impl true
  def analyze(_all_nodes, _opts), do: []
end
