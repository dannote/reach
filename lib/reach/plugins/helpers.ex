defmodule Reach.Plugins.Helpers do
  @moduledoc "Shared helpers for plugin callback implementations."

  alias Reach.IR

  def find_vars_in(node) do
    node |> IR.all_nodes() |> Enum.filter(&(&1.type == :var))
  end
end
