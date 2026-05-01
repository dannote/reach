defmodule Reach.CLI.JSONEnvelope do
  @moduledoc false

  @enforce_keys [:command, :data]
  defstruct [:command, :data, tool: nil]
end

if Code.ensure_loaded?(Jason.Encoder) do
  defimpl Jason.Encoder, for: Reach.CLI.JSONEnvelope do
    def encode(%{command: command, tool: tool, data: data}, opts) do
      data
      |> Map.merge(%{command: command})
      |> maybe_put_tool(tool)
      |> Jason.Encode.map(opts)
    end

    defp maybe_put_tool(data, nil), do: data
    defp maybe_put_tool(data, tool), do: Map.put(data, :tool, tool)
  end
end
