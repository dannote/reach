defmodule Reach.CLI.Commands.OTP do
  @moduledoc """
  Shows GenServer state machines, missing message handlers, and hidden coupling.

      mix reach.otp
      mix reach.otp UserWorker
      mix reach.otp --format json

  ## Options

    * `--format` — output format: `text` (default), `json`, `oneline`
    * `--concurrency` — show Task/monitor/spawn and supervisor topology
    * `--state` — focus on state-machine output (accepted for canonical CLI compatibility)
    * `--messages` — focus on message-handler output (accepted for canonical CLI compatibility)
    * `--supervision` — focus on supervision output (accepted for canonical CLI compatibility)

  """

  alias Reach.CLI.Commands.OTP.Concurrency
  alias Reach.CLI.Project
  alias Reach.CLI.Render.OTP, as: OTPRender
  alias Reach.OTP.Analysis, as: OTPAnalysis

  def run(opts, target_args \\ []) do
    format = opts[:format] || "text"

    if opts[:concurrency] do
      Concurrency.run_opts(opts, command: "reach.otp")
    else
      {project, scope} = load_project_and_scope(target_args, opts)
      result = OTPAnalysis.run(project, scope)
      OTPRender.render(result, format, opts)
    end
  end

  defp load_project_and_scope([target | _rest], opts) do
    if File.exists?(target) do
      {Project.load(paths: [target], quiet: opts[:format] == "json"), nil}
    else
      {Project.load(quiet: opts[:format] == "json"), target}
    end
  end

  defp load_project_and_scope([], opts), do: {Project.load(quiet: opts[:format] == "json"), nil}
end
