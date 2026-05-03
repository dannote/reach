defmodule Reach.CLI.Commands.Check.DeadCode do
  @moduledoc false

  alias Reach.Check.DeadCode, as: DeadCodeCheck
  alias Reach.CLI.Project
  alias Reach.CLI.Render.Check.DeadCode, as: DeadCodeRender

  def run(opts, positional, command \\ "reach.check") do
    format = opts[:format] || "text"

    Project.compile(format == "json")

    files = DeadCodeCheck.collect_files(opts[:path] || List.first(positional))
    unless format == "json", do: Mix.shell().info("Analyzing #{length(files)} file(s)...")

    findings = DeadCodeCheck.run(files)
    DeadCodeRender.render(findings, format, command)
  end
end
