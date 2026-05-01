defmodule Reach.Inspect.Context do
  @moduledoc """
  Builds agent-readable context bundles for a single target function.
  """

  alias Reach.CLI.Project
  alias Reach.Effects
  alias Reach.Inspect.Data
  alias Reach.IR

  def build(project, mfa, func, opts \\ []) do
    depth = opts[:depth] || 3

    %{
      target: mfa,
      location: location(func),
      effects: effects(func),
      deps: %{
        callers: Project.callers(project, mfa, 1),
        callees: Project.callees(project, mfa, depth)
      },
      impact: %{
        direct_callers: Project.callers(project, mfa, 1),
        transitive_callers: Project.callers(project, mfa, opts[:depth] || 4)
      },
      data: Data.summary(project, func, opts[:variable])
    }
  end

  def location(func) do
    span = func.source_span || %{}
    %{file: span[:file], line: span[:start_line]}
  end

  def effects(func) do
    func
    |> IR.all_nodes()
    |> Enum.map(&Effects.classify/1)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(&to_string/1)
  end
end
