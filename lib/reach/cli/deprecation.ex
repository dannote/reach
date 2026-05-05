defmodule Reach.CLI.Deprecation do
  @moduledoc false

  @dialyzer {:nowarn_function, warn: 2}

  def warn(old, new) do
    Mix.raise("mix #{old} has been removed; use mix #{new}")
  end
end
