defmodule Reach.CLI.Commands.Map do
  @moduledoc """
  Shows a project-level map of modules, coupling, hotspots, depth, effects,
  boundaries, and data-flow summaries.

      mix reach.map
      mix reach.map --modules
      mix reach.map --coupling
      mix reach.map --hotspots
      mix reach.map --effects
      mix reach.map --boundaries
      mix reach.map --depth
      mix reach.map --data
      mix reach.map --format json

  ## Options

    * `--format` — output format: `text`, `json`, `oneline`
    * `--modules` — show module inventory
    * `--coupling` — show module coupling and cycles
    * `--hotspots` — show risky high-impact functions
    * `--effects` — show effect distribution
    * `--boundaries` — show mixed-effect functions
    * `--depth` — show functions ranked by dominator depth
    * `--data` — show cross-function data-flow summary
    * `--top` — pass top-N limit to analyses that support it
    * `--sort` — sort modules/coupling sections (`name`, `functions`, `complexity`, `afferent`, `efferent`, `instability`)
    * `--module` — restrict effects to a module name fragment
    * `--min` — minimum distinct effects for `--boundaries` (default: 2)
    * `--orphans` — with `--coupling`, show only orphan modules
    * `--graph` — render a terminal graph for graph-capable sections

  """

  alias Reach.CLI.Project
  alias Reach.CLI.Render.Map, as: MapRender
  alias Reach.Map.Analysis, as: MapAnalysis

  def run(opts, positional \\ []) do
    render_map(opts, positional)
  end

  defp render_map(opts, path_args) do
    path = List.first(path_args)
    project = load_project(path, opts)
    sections = selected_keys(opts)

    sections =
      if sections == [], do: [:hotspots, :boundaries, :coupling, :modules], else: sections

    if opts[:graph] do
      MapRender.render_graph(project, sections, graph_data(project, sections, opts, path))
    else
      result = %{
        command: "reach.map",
        summary: MapAnalysis.summary(project, path),
        sections: Map.new(sections, &{&1, MapAnalysis.section_data(project, &1, opts, path)})
      }

      MapRender.render(result, opts[:format] || "text")
    end
  end

  defp selected_keys(opts) do
    [:modules, :coupling, :hotspots, :effects, :boundaries, :depth, :data, :xref]
    |> Enum.filter(&opts[&1])
    |> Enum.map(fn
      :xref -> :data
      key -> key
    end)
    |> Enum.uniq()
  end

  defp load_project(nil, opts), do: Project.load(quiet: opts[:format] == "json")
  defp load_project(path, opts), do: Project.load(paths: [path], quiet: opts[:format] == "json")

  defp graph_data(project, sections, opts, path) do
    %{
      effects: graph_section_data(project, sections, :effects, opts, path),
      depth: graph_section_data(project, sections, :depth, opts, path)
    }
  end

  defp graph_section_data(project, sections, section, opts, path) do
    if section in sections, do: MapAnalysis.section_data(project, section, opts, path), else: nil
  end
end
