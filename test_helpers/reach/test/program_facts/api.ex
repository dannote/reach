defmodule Reach.Test.ProgramFacts.API do
  @moduledoc false

  alias Reach.Test.ProgramFacts.{Normalize, Project}

  def analyze(program) do
    Project.with_project(program, fn _dir, project -> project end)
  end

  def modules(program) do
    program
    |> analyze()
    |> Map.fetch!(:modules)
    |> Normalize.modules()
  end

  def call_graph(program), do: analyze(program).call_graph

  def call_edges(program) do
    program
    |> call_graph()
    |> Graph.edges()
    |> Normalize.call_edges()
  end
end
