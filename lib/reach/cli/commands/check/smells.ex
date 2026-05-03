defmodule Reach.CLI.Commands.Check.Smells do
  @moduledoc false

  alias Reach.Check.Smells, as: SmellsCheck
  alias Reach.CLI.Project
  alias Reach.CLI.Render.Check.Smells, as: SmellsRender
  alias Reach.Config

  def run(opts, positional, command \\ "reach.check") do
    format = opts[:format] || "text"
    path = opts[:path] || List.first(positional)

    project_opts = [quiet: opts[:format] == "json"]
    project_opts = if path, do: Keyword.put(project_opts, :paths, [path]), else: project_opts
    project = Project.load(project_opts)

    findings = SmellsCheck.run(project, smells_config())
    SmellsRender.render(findings, format, command)
  end

  defp smells_config do
    if File.exists?(".reach.exs") do
      {config, _binding} = Code.eval_file(".reach.exs")
      Config.normalize(config)
    else
      Config.normalize([])
    end
  end
end
