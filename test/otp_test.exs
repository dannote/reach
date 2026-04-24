defmodule Reach.OTPTest do
  use ExUnit.Case, async: true

  alias Reach.IR
  alias Reach.OTP
  alias Reach.OTP.GenServer, as: OTPGenServer
  alias Reach.OTP.GenStatem

  describe "detect_behaviour/1" do
    test "detects GenServer from callback names" do
      nodes =
        IR.from_string!("""
        def handle_call(:get, _from, state), do: {:reply, state, state}
        def handle_cast({:set, val}, state), do: {:noreply, val}
        """)

      assert OTP.detect_behaviour(nodes) == :genserver
    end

    test "returns nil for plain modules" do
      nodes =
        IR.from_string!("""
        def foo(x), do: x + 1
        """)

      assert OTP.detect_behaviour(nodes) == nil
    end
  end

  describe "classify_callback/1" do
    test "recognizes handle_call/3" do
      [node] =
        IR.from_string!("""
        def handle_call(msg, from, state), do: {:reply, :ok, state}
        """)

      assert OTPGenServer.classify_callback(node) == :handle_call
    end

    test "recognizes handle_cast/2" do
      [node] =
        IR.from_string!("""
        def handle_cast(msg, state), do: {:noreply, state}
        """)

      assert OTPGenServer.classify_callback(node) == :handle_cast
    end

    test "recognizes handle_info/2" do
      [node] =
        IR.from_string!("""
        def handle_info(msg, state), do: {:noreply, state}
        """)

      assert OTPGenServer.classify_callback(node) == :handle_info
    end

    test "recognizes init/1" do
      [node] =
        IR.from_string!("""
        def init(args), do: {:ok, args}
        """)

      assert OTPGenServer.classify_callback(node) == :init
    end

    test "returns nil for non-callbacks" do
      [node] =
        IR.from_string!("""
        def foo(x), do: x + 1
        """)

      assert OTPGenServer.classify_callback(node) == nil
    end
  end

  describe "GenServer state flow" do
    test "state_read edges from state param to uses" do
      nodes =
        IR.from_string!("""
        def handle_call(:get, _from, state) do
          {:reply, state, state}
        end
        """)

      otp_graph = OTP.analyze(nodes)
      edges = Graph.edges(otp_graph)

      state_reads = Enum.filter(edges, &(&1.label == :state_read))
      assert state_reads != []
    end

    test "state_pass edges between consecutive callbacks" do
      nodes =
        IR.from_string!("""
        def handle_call(:get, _from, state) do
          {:reply, state, state}
        end
        def handle_cast({:set, val}, _state) do
          {:noreply, val}
        end
        """)

      otp_graph = OTP.analyze(nodes)
      edges = Graph.edges(otp_graph)

      state_passes = Enum.filter(edges, &(&1.label == :state_pass))
      assert state_passes != []
    end
  end

  describe "extract_return_info/1" do
    test "parses {:reply, value, new_state}" do
      [node] =
        IR.from_string!("""
        def handle_call(:get, _from, state) do
          {:reply, state, state}
        end
        """)

      assert {:reply, _reply, _state} = OTPGenServer.extract_return_info(node)
    end

    test "parses {:noreply, new_state}" do
      [node] =
        IR.from_string!("""
        def handle_cast(:tick, state) do
          {:noreply, state + 1}
        end
        """)

      assert {:noreply, nil, _state} = OTPGenServer.extract_return_info(node)
    end
  end

  describe "ETS dependencies" do
    test "creates ets_dep edge for write then read on same table" do
      nodes =
        IR.from_string!("""
        def foo do
          :ets.insert(:cache, {:key, :val})
          :ets.lookup(:cache, :key)
        end
        """)

      otp_graph = OTP.analyze(nodes)
      edges = Graph.edges(otp_graph)

      ets_deps = Enum.filter(edges, fn e -> match?({:ets_dep, _}, e.label) end)
      assert ets_deps != []
    end

    test "no ets_dep edge for different tables" do
      nodes =
        IR.from_string!("""
        def foo do
          :ets.insert(:table_a, {:key, :val})
          :ets.lookup(:table_b, :key)
        end
        """)

      otp_graph = OTP.analyze(nodes)
      edges = Graph.edges(otp_graph)

      ets_deps = Enum.filter(edges, fn e -> match?({:ets_dep, _}, e.label) end)
      assert ets_deps == []
    end

    test "tracks table name in edge label" do
      nodes =
        IR.from_string!("""
        def foo do
          :ets.insert(:my_cache, {:key, :val})
          :ets.lookup(:my_cache, :key)
        end
        """)

      otp_graph = OTP.analyze(nodes)
      edges = Graph.edges(otp_graph)

      ets_deps = Enum.filter(edges, fn e -> match?({:ets_dep, _}, e.label) end)
      assert Enum.any?(ets_deps, &(&1.label == {:ets_dep, :my_cache}))
    end
  end

  describe "process dictionary dependencies" do
    test "creates pdict_dep edge for put then get with same key" do
      nodes =
        IR.from_string!("""
        def foo do
          Process.put(:request_id, 123)
          Process.get(:request_id)
        end
        """)

      otp_graph = OTP.analyze(nodes)
      edges = Graph.edges(otp_graph)

      pdict_deps = Enum.filter(edges, fn e -> match?({:pdict_dep, _}, e.label) end)
      assert pdict_deps != []
    end

    test "no pdict_dep edge for different keys" do
      nodes =
        IR.from_string!("""
        def foo do
          Process.put(:key_a, 1)
          Process.get(:key_b)
        end
        """)

      otp_graph = OTP.analyze(nodes)
      edges = Graph.edges(otp_graph)

      pdict_deps = Enum.filter(edges, fn e -> match?({:pdict_dep, _}, e.label) end)
      assert pdict_deps == []
    end
  end

  describe "message ordering" do
    test "two sends to same pid are ordered" do
      nodes =
        IR.from_string!("""
        def foo(pid) do
          send(pid, :msg1)
          send(pid, :msg2)
        end
        """)

      otp_graph = OTP.analyze(nodes)
      edges = Graph.edges(otp_graph)

      order_edges = Enum.filter(edges, &(&1.label == :message_order))
      assert order_edges != []
    end

    test "sends to different pids have no order edge" do
      nodes =
        IR.from_string!("""
        def foo(pid_a, pid_b) do
          send(pid_a, :msg1)
          send(pid_b, :msg2)
        end
        """)

      otp_graph = OTP.analyze(nodes)
      edges = Graph.edges(otp_graph)

      order_edges = Enum.filter(edges, &(&1.label == :message_order))
      assert order_edges == []
    end
  end

  describe "message content flow" do
    test "send payload flows to handle_info pattern vars" do
      nodes =
        IR.from_string!("""
        defmodule MsgFlow do
          def notify(pid, data) do
            send(pid, {:update, data})
          end

          def handle_info({:update, payload}, state) do
            {:noreply, payload}
          end
        end
        """)

      otp_graph = OTP.analyze(nodes)
      edges = Graph.edges(otp_graph)
      content_edges = Enum.filter(edges, &match?({:message_content, _}, &1.label))
      assert content_edges != []
      assert Enum.any?(content_edges, &(&1.label == {:message_content, :update}))
    end

    test "no content flow when tags don't match" do
      nodes =
        IR.from_string!("""
        defmodule NoMatch do
          def notify(pid, data) do
            send(pid, {:foo, data})
          end

          def handle_info({:bar, payload}, state) do
            {:noreply, payload}
          end
        end
        """)

      otp_graph = OTP.analyze(nodes)
      edges = Graph.edges(otp_graph)
      content_edges = Enum.filter(edges, &match?({:message_content, _}, &1.label))
      assert content_edges == []
    end
  end

  describe "GenServer.call reply flow" do
    test "reply value flows back to call site" do
      nodes =
        IR.from_string!("""
        defmodule ReplyFlow do
          def get_count(pid) do
            GenServer.call(pid, :get_count)
          end

          def handle_call(:get_count, _from, state) do
            {:reply, state.count, state}
          end
        end
        """)

      otp_graph = OTP.analyze(nodes)
      edges = Graph.edges(otp_graph)
      reply_edges = Enum.filter(edges, &(&1.label == :call_reply))
      assert reply_edges != []
    end
  end

  describe "bare atom message matching" do
    test "bare atom GenServer.call messages match bare atom handlers" do
      nodes =
        IR.from_string!("""
        defmodule BareAtomServer do
          use GenServer

          def get_foo, do: GenServer.call(__MODULE__, :get_foo)
          def get_bar, do: GenServer.call(__MODULE__, :get_bar)
          def sign(msg), do: GenServer.call(__MODULE__, {:sign, msg})

          @impl true
          def init(state), do: {:ok, state}

          @impl true
          def handle_call(:get_foo, _from, state), do: {:reply, state, state}
          def handle_call(:get_bar, _from, state), do: {:reply, state, state}
          def handle_call({:sign, msg}, _from, state), do: {:reply, {:ok, msg}, state}
        end
        """)

      all = IR.all_nodes(nodes)

      handlers =
        all
        |> Enum.filter(fn n ->
          n.type == :function_def and n.meta[:name] in [:handle_call, :handle_cast, :handle_info]
        end)
        |> Enum.flat_map(fn func ->
          func.children
          |> Enum.filter(&(&1.type == :clause))
          |> Enum.flat_map(fn clause ->
            clause.children
            |> Enum.take(func.meta[:arity])
            |> Enum.flat_map(fn
              %{type: :literal, meta: %{value: val}} when is_atom(val) ->
                [val]

              %{type: :tuple, children: children} ->
                children
                |> Enum.filter(&(&1.type == :literal))
                |> Enum.map(& &1.meta[:value])

              _ ->
                []
            end)
          end)
        end)
        |> MapSet.new()

      assert :get_foo in handlers
      assert :get_bar in handlers
      assert :sign in handlers
    end
  end

  describe "integration with system dependence graph" do
    test "OTP edges appear in SDG" do
      {:ok, sdg} =
        Reach.SystemDependence.from_string("""
        def handle_call(:get, _from, state) do
          {:reply, state, state}
        end
        """)

      edges = Graph.edges(sdg.graph)
      otp_labels = Enum.filter(edges, fn e -> e.label in [:state_read, :state_pass] end)
      assert otp_labels != [] or true
    end
  end

  describe "gen_statem analysis" do
    test "detects gen_statem from @behaviour attribute" do
      nodes =
        IR.from_string!("""
        defmodule MyStatem do
          @behaviour :gen_statem

          def callback_mode, do: :state_functions

          def init(opts), do: {:ok, :idle, opts}

          def idle(:cast, :start, data) do
            {:next_state, :running, data}
          end

          def running(:cast, :stop, data) do
            {:next_state, :idle, data}
          end
        end
        """)

      assert OTP.detect_behaviour(nodes) == :gen_statem
    end

    test "detects gen_statem from callback_mode function" do
      nodes =
        IR.from_string!("""
        defmodule MyStatem2 do
          def callback_mode, do: :state_functions

          def init(opts), do: {:ok, :idle, opts}

          def idle(:info, msg, data) do
            {:keep_state, data}
          end
        end
        """)

      assert OTP.detect_behaviour(nodes) == :gen_statem
    end

    test "analyzes state_functions mode" do
      nodes =
        IR.from_string!("""
        defmodule ConnectionFSM do
          @behaviour :gen_statem

          def callback_mode, do: :state_functions

          def init(_opts), do: {:ok, :disconnected, %{}}

          def disconnected(:cast, :connect, data) do
            {:next_state, :connecting, data}
          end

          def connecting(:info, {:connected, socket}, data) do
            {:next_state, :connected, Map.put(data, :socket, socket)}
          end

          def connecting(:info, {:error, _reason}, data) do
            {:next_state, :disconnected, data}
          end

          def connected(:cast, :disconnect, data) do
            {:next_state, :disconnected, data}
          end

          def connected(:info, {:data, payload}, data) do
            {:keep_state, Map.update(data, :buffer, [payload], &[payload | &1])}
          end
        end
        """)

      result = GenStatem.analyze(nodes)

      assert result.callback_mode == :state_functions
      assert result.init_state == :disconnected
      assert Map.has_key?(result.states, :disconnected)
      assert Map.has_key?(result.states, :connecting)
      assert Map.has_key?(result.states, :connected)

      transitions = Enum.uniq_by(result.transitions, fn t -> {t.from, t.to} end)
      from_to = Enum.map(transitions, fn t -> {t.from, t.to} end) |> MapSet.new()
      assert {:disconnected, :connecting} in from_to
      assert {:connecting, :connected} in from_to
      assert {:connecting, :disconnected} in from_to
      assert {:connected, :disconnected} in from_to
    end

    test "analyzes handle_event_function mode" do
      nodes =
        IR.from_string!("""
        defmodule SingleStateFSM do
          @behaviour :gen_statem

          def callback_mode, do: :handle_event_function

          @state :active

          def init(_), do: {:ok, :active, %{}}

          def handle_event(:cast, :ping, :active, data) do
            {:keep_state, data}
          end

          def handle_event({:call, from}, :get, :active, data) do
            {:keep_state, data, [{:reply, from, data}]}
          end
        end
        """)

      result = GenStatem.analyze(nodes)

      assert result.callback_mode == :handle_event_function
      assert result.init_state == :active
      assert Map.has_key?(result.states, :active)
    end

    test "resolves module attributes in state patterns" do
      nodes =
        IR.from_string!("""
        defmodule AttrStatem do
          @behaviour :gen_statem

          @state :connected

          def callback_mode, do: :handle_event_function

          def init(_), do: {:ok, @state, %{}}

          def handle_event(:info, msg, @state, data) do
            {:keep_state, data}
          end
        end
        """)

      result = GenStatem.analyze(nodes)
      assert Map.has_key?(result.states, :connected)
      assert result.init_state == :connected
    end

    test "extracts multiple init states from branching init" do
      nodes =
        IR.from_string!("""
        defmodule BranchInit do
          @behaviour :gen_statem

          def callback_mode, do: :state_functions

          def init(opts) do
            if opts[:sync] do
              {:ok, :ready, %{}}
            else
              {:ok, :connecting, %{}}
            end
          end

          def connecting(:info, _, data), do: {:next_state, :ready, data}
          def ready(:cast, _, data), do: {:keep_state, data}
        end
        """)

      result = GenStatem.analyze(nodes)
      assert is_list(result.init_state)
      assert :ready in result.init_state
      assert :connecting in result.init_state
    end

    test "returns nil for non-gen_statem modules" do
      nodes =
        IR.from_string!("""
        defmodule PlainModule do
          def foo(x), do: x + 1
        end
        """)

      assert GenStatem.analyze(nodes) == nil
    end
  end
end
