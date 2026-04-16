defmodule Reach.Plugins.Helpers do
  @moduledoc false

  alias Reach.IR

  def find_vars_in(node) do
    node |> IR.all_nodes() |> Enum.filter(&(&1.type == :var))
  end
end
