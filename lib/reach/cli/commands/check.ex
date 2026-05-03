defmodule Reach.CLI.Commands.Check do
  @moduledoc """
  Runs structural validation and change-safety checks.

      mix reach.check
      mix reach.check --arch
      mix reach.check --changed --base main
      mix reach.check --dead-code
      mix reach.check --smells
      mix reach.check --candidates

  ## Options

    * `--format` — output format: `text` or `json`
    * `--arch` — check `.reach.exs` architecture policy
    * `--changed` — report changed functions and configured test hints
    * `--base` — git base ref for `--changed` (default: auto-detect `main`, `master`, or upstream)
    * `--dead-code` — find unused pure expressions
    * `--smells` — find graph/effect/data-flow performance smells
    * `--candidates` — emit advisory refactoring candidates
    * `--top` — limit candidate output for `--candidates`

  """

  alias Reach.Check.Architecture
  alias Reach.Check.Candidates
  alias Reach.Check.Changed
  alias Reach.CLI.Commands.Check.DeadCode
  alias Reach.CLI.Commands.Check.Smells
  alias Reach.CLI.Project
  alias Reach.CLI.Render.Check, as: CheckRender
  alias Reach.Config

  def run(opts, positional \\ []) do
    cond do
      opts[:arch] ->
        run_arch(opts)

      opts[:changed] ->
        run_changed(opts)

      opts[:dead_code] ->
        DeadCode.run(opts, positional, "reach.check")

      opts[:smells] ->
        Smells.run(opts, positional, "reach.check")

      opts[:candidates] ->
        run_candidates(opts, positional)

      true ->
        run_default(opts)
    end
  end

  defp run_default(opts) do
    if Config.read() != [] do
      run_arch(opts)
    else
      CheckRender.render_no_default()
    end
  end

  defp run_arch(opts) do
    config = Config.read!()

    result =
      case Architecture.config_violations(config) do
        [] ->
          project = Project.load(quiet: opts[:format] == "json")
          Architecture.run(project, config)

        violations ->
          %{config: ".reach.exs", status: "failed", violations: violations}
      end

    CheckRender.render_result(result, opts[:format], &CheckRender.render_arch_text/1)

    if result.violations != [] do
      Mix.raise("Architecture policy failed")
    end
  end

  defp run_changed(opts) do
    config = Config.read()
    project = Project.load(quiet: opts[:format] == "json")
    result = Changed.run(project, config, base: opts[:base])

    CheckRender.render_result(result, opts[:format], &CheckRender.render_changed_text/1)
  end

  defp run_candidates(opts, positional) do
    project = load_candidates_project(opts, positional)
    config = Config.read()
    result = Candidates.run(project, config, top: opts[:top] || 40)

    CheckRender.render_result(result, opts[:format], &CheckRender.render_candidates_text/1)
  end

  defp load_candidates_project(opts, positional) do
    path = opts[:path] || List.first(positional)

    if path do
      Project.load(paths: [path], quiet: opts[:format] == "json")
    else
      Project.load(quiet: opts[:format] == "json")
    end
  end
end
