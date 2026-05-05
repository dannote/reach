defmodule Reach.Trace.Pattern do
  @moduledoc "Plugin-dispatched trace pattern presets."

  def compile(pattern, plugins \\ []) do
    Reach.Plugin.trace_pattern(plugins, pattern) || compile_generic(pattern)
  end

  defp compile_generic("System.cmd") do
    fn node ->
      node.type == :call and node.meta[:module] == System and node.meta[:function] == :cmd
    end
  end

  defp compile_generic(pattern) do
    fn
      %{type: :var, meta: %{name: name}} -> to_string(name) == pattern
      %{type: :call, meta: meta} -> to_string(meta[:function] || "") =~ pattern
      _node -> false
    end
  end
end
