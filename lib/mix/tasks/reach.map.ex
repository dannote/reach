defmodule Mix.Tasks.Reach.Map do
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

    * `--format` — output format passed to delegated analyses: `text`, `json`, `oneline`
    * `--modules` — show module inventory
    * `--coupling` — show module coupling and cycles
    * `--hotspots` — show risky high-impact functions
    * `--effects` — show effect distribution
    * `--boundaries` — show mixed-effect functions
    * `--depth` — show functions ranked by dominator depth
    * `--data` — show cross-function data-flow summary
    * `--top` — pass top-N limit to analyses that support it

  """

  use Mix.Task

  alias Reach.CLI.TaskRunner

  @shortdoc "Project structure and risk map"

  @switches [
    format: :string,
    modules: :boolean,
    coupling: :boolean,
    hotspots: :boolean,
    effects: :boolean,
    boundaries: :boolean,
    depth: :boolean,
    data: :boolean,
    xref: :boolean,
    top: :integer,
    sort: :string
  ]

  @aliases [f: :format]

  @impl Mix.Task
  def run(args) do
    {opts, positional, _} = OptionParser.parse(args, switches: @switches, aliases: @aliases)
    path_args = positional

    selections = selected_sections(opts)
    sections = if selections == [], do: default_sections(), else: selections

    Enum.each(sections, fn {title, task, extra_args} ->
      print_section(title, length(sections))
      TaskRunner.run(task, build_args(opts, extra_args, path_args))
    end)
  end

  defp selected_sections(opts) do
    [
      {:modules, "Modules", "reach.modules", []},
      {:coupling, "Coupling", "reach.coupling", []},
      {:hotspots, "Hotspots", "reach.hotspots", []},
      {:effects, "Effects", "reach.effects", []},
      {:boundaries, "Effect Boundaries", "reach.boundaries", []},
      {:depth, "Control Depth", "reach.depth", []},
      {:data, "Cross-function Data Flow", "reach.xref", []},
      {:xref, "Cross-function Data Flow", "reach.xref", []}
    ]
    |> Enum.flat_map(fn {key, title, task, extra_args} ->
      if opts[key], do: [{title, task, extra_args}], else: []
    end)
  end

  defp default_sections do
    [
      {"Modules", "reach.modules", []},
      {"Hotspots", "reach.hotspots", ["--top", "10"]},
      {"Coupling", "reach.coupling", []},
      {"Effect Boundaries", "reach.boundaries", []}
    ]
  end

  defp build_args(opts, extra_args, path_args) do
    []
    |> maybe_put("--format", opts[:format])
    |> maybe_put("--top", opts[:top])
    |> maybe_put("--sort", opts[:sort])
    |> Kernel.++(extra_args)
    |> Kernel.++(path_args)
  end

  defp maybe_put(args, _flag, nil), do: args
  defp maybe_put(args, flag, value), do: args ++ [flag, to_string(value)]

  defp print_section(_title, 1), do: :ok

  defp print_section(title, _count) do
    IO.puts("\n== #{title} ==")
  end
end
