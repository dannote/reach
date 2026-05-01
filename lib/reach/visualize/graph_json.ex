defmodule Reach.Visualize.GraphJSON do
  @moduledoc false

  @derive Jason.Encoder
  @enforce_keys [:control_flow, :call_graph, :data_flow]
  defstruct [:control_flow, :call_graph, :data_flow]
end
