# ExPDG OTP Semantic Model

ExPDG doesn't just analyze Elixir syntax — it understands **OTP and BEAM
runtime primitives** as first-class program structures with their own
dependence semantics.

A GenServer isn't just "a module with some functions". It's a **stateful
sequential process** where state flows through callback returns, messages
arrive via the mailbox, and callers block on replies. The PDG must model this.

**Scope:** BEAM runtime and OTP standard library only. No library-specific
models (Phoenix, Ecto, etc.) — those belong in extension plugins.

---

## Processes and Messages

The fundamental BEAM concurrency primitive. Everything else builds on this.

### send / receive

```elixir
send(pid, {:work, data})

receive do
  {:work, data} -> process(data)
  {:stop, reason} -> exit(reason)
after
  5000 -> :timeout
end
```

What the PDG models:

```
[send(pid, {:work, data})]
    ──message{pattern: {:work, _}}──→
[receive clause {:work, data}]

[send(pid, {:stop, reason})]
    ──message{pattern: {:stop, _}}──→
[receive clause {:stop, reason}]
```

#### Edge types
- `message_send` — `send/2`, `Process.send/3`, `Process.send_after/3,4`
- `message_receive` — `receive` clause that matches the sent pattern
- `message_data` — data flow through the message payload
- `message_order` — two sends to same pid are ordered (mailbox is FIFO)

#### What this enables
```elixir
# "Two sends to same pid — order matters"
from {a, b} in pdg,
  where: message_send?(a),
  where: message_send?(b),
  where: same_target_pid?(a, b),
  where: sequential?(a, b)

# "receive clause that nothing sends to"
from r in pdg,
  where: r.type == :receive_clause,
  where: not exists(s, &message_receive?(s, r))

# "Data flows from sender to receiver"
from {send_node, recv_node} in pdg,
  where: message_send?(send_node),
  where: message_receive?(send_node, recv_node),
  where: data_flows?(send_node, recv_node)
```

### spawn / Task

Process creation establishes a parent-child relationship and passes
initial data via closures or MFA arguments.

```elixir
spawn(fn -> do_work(data) end)
Task.async(fn -> compute(x) end)
Task.await(task)
```

#### Edge types
- `spawn_edge` — process creation
- `spawn_data` — data captured in closure/args flows to child
- `task_result` — Task.await receives result from child
- `link_edge` — linked processes (crash propagation)
- `monitor_edge` — monitoring relationship

---

## GenServer

### State threading

A GenServer's state flows through a hidden channel: the return value of each
callback feeds into the next callback's last argument.

```elixir
def handle_call(:get, _from, state) do
  {:reply, state.count, state}              # state passes through unchanged
end

def handle_call({:set, n}, _from, state) do
  {:reply, :ok, %{state | count: n}}        # state modified and forwarded
end
```

What the PDG models:

```
[handle_call(:get)] ──state_read──→ [state.count]
                    ──state_pass──→ [next callback state arg]

[handle_call({:set,n})] ──state_write──→ [%{state | count: n}]
                        ──state_pass───→ [next callback state arg]
```

#### Edge types
- `state_read` — callback reads from state argument
- `state_write` — callback returns modified state
- `state_pass` — state flows from one callback's return to next callback's arg
- `init_state` — `init/1` return establishes initial state

#### What this enables
```elixir
# "Does this handle_call modify state?"
from n in pdg,
  where: in_callback?(n, :handle_call),
  where: genserver_state_write?(n)

# "What callbacks affect the :count field?"
from n in pdg,
  where: genserver_state_write?(n),
  where: writes_field?(n, :count)

# "Does state leak to callers?"
from {read, reply} in pdg,
  where: genserver_state_read?(read),
  where: reply.type == :reply_value,
  where: data_flows?(read, reply),
  where: not passes_through?(read, reply, &copy?/1)
```

### Call / cast / info flow

```
Caller                          GenServer process
──────                          ─────────────────
GenServer.call(pid, msg)  ───call_msg───→  handle_call(msg, from, state)
                          ←──call_reply──  {:reply, result, new_state}

GenServer.cast(pid, msg)  ───cast_msg───→  handle_cast(msg, state)

send(pid, msg)            ───info_msg───→  handle_info(msg, state)
Process.send_after(...)   ───info_msg───→  handle_info(msg, state)
```

#### Edge types
- `call_msg` — message from caller to handle_call
- `call_reply` — reply from handle_call to caller
- `cast_msg` — message from caller to handle_cast
- `info_msg` — message to handle_info (inherits from process-level `message_send`)

---

## Supervisor

### Child dependency model

Supervisors define startup order and restart dependencies between children.

```elixir
children = [
  {Registry, keys: :unique, name: MyApp.Registry},
  {MyApp.Cache, []},
  {MyApp.Worker, []}
]
Supervisor.init(children, strategy: :one_for_one)
```

What the PDG models:

```
[Registry] ──startup_before──→ [MyApp.Cache] ──startup_before──→ [MyApp.Worker]
```

With `:one_for_all` or `:rest_for_one`, restart edges also exist:
```
# :rest_for_one — crash of Cache restarts Worker too
[MyApp.Cache] ──restart_triggers──→ [MyApp.Worker]
```

#### Edge types
- `startup_order` — child A starts before child B (list position)
- `restart_triggers` — crash of A causes restart of B (strategy-dependent)

#### Restart strategies
- `:one_for_one` — no restart cascades, only `startup_order`
- `:one_for_all` — any crash restarts all → full `restart_triggers` mesh
- `:rest_for_one` — crash restarts all later children → forward `restart_triggers`

#### What this enables
```elixir
# "If Cache crashes, what else restarts?"
from {crashed, affected} in pdg,
  where: crashed.child_id == MyApp.Cache,
  where: restart_triggers?(crashed, affected)

# "Circular startup dependency?" (runtime calls contradict supervisor order)
from {a, b} in pdg,
  where: startup_order?(a, b),
  where: runtime_calls?(b, a)  # B calls A at startup but A starts after B
```

---

## ETS

### Table operations

ETS is shared mutable state — the hardest thing for dependence analysis.

```elixir
:ets.new(:my_table, [:named_table, :set, :public])
:ets.insert(:my_table, {key, value})
result = :ets.lookup(:my_table, key)
```

What the PDG models:

```
[:ets.insert(:my_table, ...)] ──ets_write{table: :my_table}──→ [shared state]
[:ets.lookup(:my_table, ...)] ──ets_read{table: :my_table}───→ [shared state]

# Write-before-read dependency:
[:ets.insert] ──ets_dep{table: :my_table}──→ [:ets.lookup]
```

#### Edge types
- `ets_write` — `:ets.insert`, `:ets.insert_new`, `:ets.delete`, `:ets.update_counter`, `:ets.update_element`
- `ets_read` — `:ets.lookup`, `:ets.lookup_element`, `:ets.match`, `:ets.select`, `:ets.member`, `:ets.info`
- `ets_dep` — read may depend on prior write (same table)
- `ets_create` — `:ets.new` creates table
- `ets_atomic` — `:ets.update_counter` and `:ets.insert_new` are atomic (no race)

#### Key tracking (when statically determinable)
```elixir
:ets.insert(:cache, {"user_1", data})
:ets.lookup(:cache, "user_1")          # same key → definite dependency
:ets.lookup(:cache, "user_2")          # different key → no dependency
:ets.lookup(:cache, key)               # variable key → conservative dependency
```

#### What this enables
```elixir
# "Non-atomic read-modify-write?"
from {read, write} in pdg,
  where: ets_read?(read),
  where: ets_write?(write),
  where: same_table?(read, write),
  where: data_flows?(read, write),
  where: not ets_atomic?(read, write)

# "Table written but never read?"
from w in pdg,
  where: ets_write?(w),
  where: not exists(r, &(ets_read?(r) and same_table?(w, r)))
```

---

## Process Dictionary

Simpler than ETS but same problem: hidden mutable state scoped to a process.

```elixir
Process.put(:request_id, id)
# ... later ...
rid = Process.get(:request_id)
```

#### Edge types
- `pdict_write` — `Process.put/2`
- `pdict_read` — `Process.get/1,2`
- `pdict_dep` — read depends on write (same key)
- `pdict_delete` — `Process.delete/1`

#### What this enables
```elixir
# "Process dict used to pass data between different functions?"
from {write, read} in pdg,
  where: pdict_write?(write),
  where: pdict_read?(read),
  where: not same_function?(write, read)

# "Process dict key written but never read?"
from w in pdg,
  where: pdict_write?(w),
  where: not exists(r, &(pdict_read?(r) and same_pdict_key?(w, r)))
```

---

## Application Environment

```elixir
Application.put_env(:my_app, :key, value)
Application.get_env(:my_app, :key)
Application.fetch_env!(:my_app, :key)
```

#### Edge types
- `app_env_write` — `Application.put_env/3,4`
- `app_env_read` — `Application.get_env/2,3`, `Application.fetch_env/2`, `Application.fetch_env!/2`
- `app_env_dep` — read depends on write (same app + key)

Simpler than ETS: global, rarely written after boot, mostly read.
But `put_env` at runtime does happen and creates real dependencies.

---

## Monitors and Links

```elixir
ref = Process.monitor(pid)
Process.link(pid)
```

#### Edge types
- `monitor_edge` — A monitors B (A receives :DOWN when B dies)
- `link_edge` — A and B are linked (crash propagation)
- `trap_exit` — process traps exits, receives {:EXIT, pid, reason} as message

These matter for understanding crash propagation and cleanup flow.

---

## Detection strategy

How does ExPDG recognize OTP patterns?

### Behaviour detection (at IR build time)
```elixir
use GenServer             → tag module as :genserver
use Supervisor            → tag module as :supervisor
use Agent                 → tag module as :agent
@behaviour GenServer      → tag module as :genserver
@behaviour :gen_server    → tag module as :genserver (Erlang)
```

### Callback recognition
Once behaviour is known, callbacks are recognized by name + arity:
- `init/1`, `handle_call/3`, `handle_cast/2`, `handle_info/2`, `terminate/2` → GenServer
- `init/1` returning child specs → Supervisor

### Return value interpretation
GenServer callback returns have typed structure:
- `{:reply, response, new_state}` → `call_reply` edge + `state_write`
- `{:noreply, new_state}` → `state_write` only
- `{:stop, reason, state}` → termination edge
- `{:reply, response, new_state, timeout}` → adds timeout → info_msg edge

### Built-in function recognition
No behaviour detection needed — just function identity:
- `:ets.*` → ETS edges
- `Process.put/get/delete` → pdict edges
- `send/2`, `Process.send/3` → message edges
- `spawn/1,3`, `spawn_link/1,3` → spawn edges
- `Task.async/1`, `Task.await/1,2` → task edges
- `Process.monitor/1`, `Process.link/1` → monitor/link edges
- `Application.get_env/2,3`, `Application.put_env/3,4` → app env edges
- `GenServer.call/2,3`, `GenServer.cast/2` → call/cast edges

---

## Implementation priority

| Concept | Phase | Difficulty | Value |
|---------|-------|------------|-------|
| `send`/`receive` message deps | 5b | Medium | Very high |
| GenServer state threading | 5b | Medium | Very high |
| GenServer call/cast/info edges | 5b | Medium | Very high |
| ETS read/write deps | 5b | Medium | High |
| `spawn`/`Task` process creation | 5b | Medium | High |
| Process dictionary | 5b | Easy | Medium |
| Supervisor child order/restart | 5b | Easy | Medium |
| Application env | 5b | Easy | Low |
| Monitors/links (crash flow) | 6 | Medium | Medium |
| Agent (thin wrapper over GenServer) | 6 | Easy | Low |
| `:persistent_term` | 6 | Easy | Low |
| Registry lookups | 6 | Hard | Medium |
| Dynamic supervisors | 7 | Hard | Low |

Process messaging + GenServer + ETS cover the vast majority of real-world
OTP state management patterns.

---

## Extension point for library-specific models

The core models above are BEAM/OTP only. Library-specific analysis
(Phoenix, Ecto, Absinthe, etc.) belongs in **extension modules** that:

1. Register additional edge types
2. Register additional node recognizers (e.g., "this call is a PubSub broadcast")
3. Register additional built-in checks
4. Depend on ExPDG as a library, not the other way around

```elixir
# Future — NOT part of core ExPDG
defmodule ExPDGPhoenix do
  use ExPDG.Extension

  register_edge_type :pubsub_broadcast
  register_edge_type :assign_write
  register_edge_type :assign_read

  register_recognizer &phoenix_pubsub_recognizer/1
  register_recognizer &liveview_assign_recognizer/1
end
```

This keeps the core focused and the dependency graph clean.
