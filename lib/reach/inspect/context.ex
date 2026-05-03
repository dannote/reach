defmodule Reach.Inspect.Context do
  @moduledoc """
  Builds agent-readable context bundles for a single target function.
  """

  alias Reach.Effects
  alias Reach.Inspect.Data
  alias Reach.IR
  alias Reach.Project.Query

  def build(project, mfa, func, opts \\ []) do
    configured_depth = opts[:depth]
    depth = configured_depth || 3
    direct_callers = Query.callers(project, mfa, 1)

    %{
      target: mfa,
      location: location(func),
      effects: effects(func),
      deps: %{
        callers: direct_callers,
        callees: Query.callees(project, mfa, depth)
      },
      impact: %{
        direct_callers: direct_callers,
        transitive_callers: Query.callers(project, mfa, configured_depth || 4)
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
