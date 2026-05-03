defmodule Reach.Trace.Pattern do
  @moduledoc false

  @param_names [:params, :user_params, :body_params]

  def compile(pattern) when pattern in ["conn.params", "params"] do
    fn node ->
      node.type == :var and node.meta[:name] in @param_names
    end
  end

  def compile(pattern) when pattern in ["Repo", "Repo.query"] do
    fn node ->
      node.type == :call and repo_call?(node)
    end
  end

  def compile("System.cmd") do
    fn node ->
      node.type == :call and node.meta[:module] == System and node.meta[:function] == :cmd
    end
  end

  def compile(pattern) do
    fn node ->
      node.type == :call and to_string(node.meta[:function] || "") =~ pattern
    end
  end

  defp repo_call?(node) do
    (is_atom(node.meta[:module]) and to_string(node.meta[:module]) =~ "Repo") or
      node.meta[:module] == Ecto.Adapters.SQL
  end
end
