defmodule Reach.CLI.Deprecation do
  @moduledoc false

  @delegation_key {__MODULE__, :delegated}

  def delegated(fun) when is_function(fun, 0) do
    previous = Process.get(@delegation_key, false)
    Process.put(@delegation_key, true)

    try do
      fun.()
    after
      Process.put(@delegation_key, previous)
    end
  end

  def warn(old, new) do
    unless Process.get(@delegation_key, false) do
      IO.puts(:stderr, "warning: mix #{old} is deprecated; use mix #{new}")
    end
  end
end
