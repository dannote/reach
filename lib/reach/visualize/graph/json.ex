defmodule Reach.Visualize.Graph.JSON do
  @moduledoc "Serializes graph data to JSON for frontend rendering."

  @derive Jason.Encoder
  @enforce_keys [:control_flow, :call_graph, :data_flow]
  defstruct [:control_flow, :call_graph, :data_flow]
end
