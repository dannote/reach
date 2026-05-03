defmodule Reach.CLI.Requirements do
  @moduledoc false

  @json_hint "Add {:jason, \"~> 1.0\"} to your deps."

  def json!(context \\ "JSON output") do
    unless Code.ensure_loaded?(Jason) do
      Mix.raise("Jason is required for #{context}. #{@json_hint}")
    end
  end
end
