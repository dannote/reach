defmodule Reach.OTP do
  @moduledoc false

  alias Reach.IR
  alias Reach.IR.Node
  alias Reach.OTP.Coupling
  alias Reach.OTP.GenServer, as: OTPGenServer
  alias Reach.OTP.GenStatem

  @type otp_edge_label ::
          :state_read
          | :state_write
          | :state_pass
          | :init_state
          | {:call_msg, atom()}
          | {:cast_msg, atom()}
          | :call_reply
          | {:ets_dep, atom() | nil}
          | {:pdict_dep, atom() | nil}
          | :message_order
          | {:state_transition, atom(), atom()}

  @doc """
  Adds OTP semantic edges to a libgraph based on IR analysis.

  Returns a new `Graph.t()` containing only OTP edges. Merge this
  with the existing PDG/SDG graph.
  """
  @spec analyze([Node.t()]) :: Graph.t()
  def analyze(ir_nodes, opts \\ []) do
    all_nodes = Keyword.get_lazy(opts, :all_nodes, fn -> IR.all_nodes(ir_nodes) end)

    Graph.new()
    |> OTPGenServer.add_edges(all_nodes)
    |> Coupling.add_edges(all_nodes)
  end

  @doc """
  Detects which OTP behaviour a module uses, based on IR nodes.

  Returns `:genserver`, `:gen_statem`, `:supervisor`, `:agent`, or `nil`.
  """
  @spec detect_behaviour([Node.t()]) :: atom() | nil
  def detect_behaviour(ir_nodes) do
    all_nodes = IR.all_nodes(ir_nodes)
    detect_from_use(all_nodes) || detect_from_structure(all_nodes)
  end

  defp detect_from_use(all_nodes) do
    use_call =
      Enum.find(all_nodes, fn node ->
        node.type == :call and
          node.meta[:function] == :use and
          node.meta[:kind] == :local
      end)

    case use_call do
      %Node{children: [%Node{type: :literal, meta: %{value: GenServer}} | _]} -> :genserver
      %Node{children: [%Node{meta: %{value: Supervisor}} | _]} -> :supervisor
      %Node{children: [%Node{meta: %{value: Agent}} | _]} -> :agent
      _ -> nil
    end
  end

  defp detect_from_structure(all_nodes) do
    cond do
      GenStatem.detect?(all_nodes) -> :gen_statem
      has_genserver_callbacks?(all_nodes) -> :genserver
      true -> nil
    end
  end

  defp has_genserver_callbacks?(all_nodes) do
    all_nodes
    |> Enum.filter(&(&1.type == :function_def))
    |> Enum.any?(fn fd ->
      OTPGenServer.classify_callback(fd) in [:handle_call, :handle_cast, :handle_info]
    end)
  end
end
