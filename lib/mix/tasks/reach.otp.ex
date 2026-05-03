defmodule Mix.Tasks.Reach.Otp do
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

  use Mix.Task

  alias Reach.CLI.Commands.OTP
  alias Reach.CLI.Options
  alias Reach.CLI.Pipe

  @shortdoc "Show OTP state machine analysis"

  @switches [
    format: :string,
    graph: :boolean,
    concurrency: :boolean,
    state: :boolean,
    messages: :boolean,
    supervision: :boolean
  ]
  @aliases [f: :format]

  @impl Mix.Task
  def run(args) do
    Pipe.safely(fn ->
      {opts, target_args} = Options.parse(args, @switches, @aliases)
      OTP.run(opts, target_args)
    end)
  end
end
