# Reach

Program dependence graph for Elixir and Erlang.

Reach builds a graph that captures **what depends on what** in your code.
Given any expression, you can ask: what affects it? What does it affect?
Can these two statements be safely reordered? Does user input reach this
database call without sanitization?


## Use cases

### Security: taint analysis

Does user input reach a dangerous sink without sanitization?

```elixir
graph = Reach.file_to_graph!("lib/my_app_web/controllers/user_controller.ex")

# Find all Plug.Conn.params calls (taint sources)
sources = Reach.nodes(graph, type: :call, module: Plug.Conn, function: :params)

# Find all Ecto.Adapters.SQL.query calls (sinks)
sinks = Reach.nodes(graph, type: :call, module: Ecto.Adapters.SQL, function: :query)

for source <- sources, sink <- sinks do
  if Reach.data_flows?(graph, source.id, sink.id) do
    unless Reach.passes_through?(graph, source.id, sink.id, fn node ->
      node.type == :call and node.meta[:function] == :sanitize
    end) do
      IO.warn("Unsanitized input flows to SQL query at #{inspect(sink.source_span)}")
    end
  end
end
```

### Code quality: dead code and useless expressions

```elixir
graph = Reach.file_to_graph!("lib/accounts.ex")

for node <- Reach.nodes(graph, type: :call),
    Reach.pure?(node),
    not Reach.has_dependents?(graph, node.id) do
  IO.warn("Pure call result unused at #{inspect(node.source_span)}")
end
```

### Refactoring: safe reordering

```elixir
graph = Reach.file_to_graph!("lib/pipeline.ex")

for block <- Reach.nodes(graph, type: :block),
    {a, b} <- pairs(block.children) do
  if Reach.independent?(graph, a.id, b.id) do
    IO.puts("Statements at lines #{a.source_span.start_line} and " <>
      "#{b.source_span.start_line} can be safely reordered")
  end
end
```

### Clone detection: reordering-equivalent code

Two blocks with the same statements in different order are clones if
the statements are independent. `canonical_order` sorts independent
siblings by structural hash so both orderings produce the same sequence:

```elixir
# For ExDNA integration
order = Reach.canonical_order(graph, block_node_id)
hash = :erlang.phash2(Enum.map(order, fn {_, node} -> node end))
```

### OTP: GenServer state flow analysis

```elixir
graph = Reach.file_to_graph!("lib/my_server.ex")
edges = Reach.edges(graph)

# Which callbacks read state?
state_reads = Enum.filter(edges, &(&1.label == :state_read))

# Does state flow between callbacks?
state_passes = Enum.filter(edges, &(&1.label == :state_pass))

# ETS write-then-read dependencies
ets_deps = Enum.filter(edges, &match?({:ets_dep, _table}, &1.label))
```

### Concurrency: crash propagation

```elixir
graph = Reach.file_to_graph!("lib/my_supervisor.ex")
edges = Reach.edges(graph)

# Which monitors connect to which :DOWN handlers?
Enum.filter(edges, &(&1.label == :monitor_down))

# Does this process trap exits? Which handler receives them?
Enum.filter(edges, &(&1.label == :trap_exit))

# Task.async → Task.await data flow
Enum.filter(edges, &(&1.label == :task_result))

# Supervisor child startup ordering
Enum.filter(edges, &(&1.label == :startup_order))
```

## Installation

```elixir
def deps do
  [{:reach, "~> 1.0"}]
end
```

## Building a graph

```elixir
# From Elixir source
{:ok, graph} = Reach.string_to_graph("def foo(x), do: x + 1")
{:ok, graph} = Reach.file_to_graph("lib/my_module.ex")

# From Erlang source
{:ok, graph} = Reach.string_to_graph(source, language: :erlang)
{:ok, graph} = Reach.file_to_graph("src/my_module.erl")  # auto-detected

# From pre-parsed AST (for Credo/ExDNA integration)
{:ok, ast} = Code.string_to_quoted(source)
{:ok, graph} = Reach.ast_to_graph(ast)

# From compiled BEAM bytecode (sees macro-expanded code)
{:ok, graph} = Reach.module_to_graph(MyApp.Accounts)
{:ok, graph} = Reach.compiled_to_graph(source)

# Bang variants
graph = Reach.file_to_graph!("lib/my_module.ex")
```

The BEAM frontend captures code invisible to source-level analysis —
`use GenServer` callbacks, macro-expanded `try/rescue`, generated functions:

```elixir
# Source: only sees init/1 and handle_call/3
Reach.string_to_graph(genserver_source)

# BEAM: also sees child_spec/1, terminate/2, handle_info/2
Reach.compiled_to_graph(genserver_source)
```

## API reference

### Nodes

```elixir
Reach.nodes(graph)                                    # all nodes
Reach.nodes(graph, type: :call)                       # by type
Reach.nodes(graph, type: :call, module: Enum)         # by module
Reach.nodes(graph, type: :call, module: Repo, function: :insert)

node = Reach.node(graph, node_id)
node.type        #=> :call
node.meta        #=> %{module: Repo, function: :insert, arity: 1}
node.source_span #=> %{file: "lib/accounts.ex", start_line: 12, ...}
```

### Slicing

```elixir
Reach.backward_slice(graph, node_id)   # what affects this?
Reach.forward_slice(graph, node_id)    # what does this affect?
Reach.chop(graph, source_id, sink_id)  # how does A influence B?
```

### Data flow and independence

```elixir
Reach.data_flows?(graph, source_id, sink_id)
Reach.depends?(graph, id_a, id_b)
Reach.independent?(graph, id_a, id_b)
Reach.has_dependents?(graph, node_id)
Reach.passes_through?(graph, source_id, sink_id, &predicate/1)
```

### Effects

```elixir
Reach.pure?(node)              #=> true
Reach.classify_effect(node)    #=> :pure | :io | :read | :write | :send | :receive | :exception | :unknown
```

Covers `Enum`, `Map`, `List`, `String`, `Keyword`, `Tuple`, `Integer`,
`Float`, `Atom`, `MapSet`, `Range`, `Regex`, `URI`, `Path`, `Base`, and
Erlang equivalents. `Enum.each` correctly classified as impure.

### Dependencies

```elixir
Reach.control_deps(graph, node_id)   #=> [{controller_id, label}, ...]
Reach.data_deps(graph, node_id)      #=> [{source_id, :variable_name}, ...]
Reach.edges(graph)                   # all dependence edges
```

### Interprocedural

```elixir
Reach.function_graph(graph, {MyModule, :my_function, 2})
Reach.context_sensitive_slice(graph, node_id)   # Horwitz-Reps-Binkley
Reach.call_graph(graph)                         # {module, function, arity} vertices
```

### Canonical ordering

```elixir
Reach.canonical_order(graph, block_id)
#=> [{node_id, %Reach.IR.Node{}}, ...] sorted so independent
#   siblings have deterministic order regardless of source order
```

### Export

```elixir
{:ok, dot} = Reach.to_dot(graph)
File.write!("graph.dot", dot)
# dot -Tpng graph.dot -o graph.png
```

## Edge types

| Label | Source | Meaning |
|-------|--------|---------|
| `{:data, var}` | DDG | Data flows through variable `var` |
| `:containment` | DDG | Parent expression depends on child sub-expression |
| `{:control, label}` | CDG | Execution controlled by branch condition |
| `:call` | SDG | Call site to callee function |
| `:parameter_in` | SDG | Argument flows to formal parameter |
| `:parameter_out` | SDG | Return value flows back to caller |
| `:summary` | SDG | Shortcut: parameter flows to return value |
| `:state_read` | OTP | GenServer callback reads state parameter |
| `:state_pass` | OTP | State flows between consecutive callbacks |
| `{:ets_dep, table}` | OTP | ETS write → read on same table |
| `{:pdict_dep, key}` | OTP | Process dictionary put → get on same key |
| `:message_order` | OTP | Sequential sends to same pid |
| `:monitor_down` | Concurrency | `Process.monitor` → `handle_info({:DOWN, ...})` |
| `:trap_exit` | Concurrency | `Process.flag(:trap_exit)` → `handle_info({:EXIT, ...})` |
| `:link_exit` | Concurrency | `spawn_link` / `Process.link` → `:EXIT` handler |
| `:task_result` | Concurrency | `Task.async` → `Task.await` data flow |
| `:startup_order` | Concurrency | Supervisor child A starts before child B |

## Architecture

```mermaid
graph TD
    Source["Source (.ex / .erl / .beam)"] --> Frontend
    Frontend["Frontend → IR Nodes<br/><i>Elixir AST · Erlang abstract forms · BEAM bytecode</i>"] --> CFG
    CFG["Control Flow Graph<br/><i>entry/exit · branching · exceptions</i>"] --> Dom
    Dom["Dominators<br/><i>post-dominator tree · dominance frontier</i>"] --> CD
    CD["Control Dependence<br/><i>Ferrante et al. 1987</i>"] --> PDG
    CFG --> DD
    DD["Data Dependence<br/><i>def-use chains · containment edges</i>"] --> PDG
    PDG["Program Dependence Graph<br/><i>control ∪ data</i>"] --> SDG
    SDG["System Dependence Graph + OTP + Concurrency<br/><i>call/summary edges · GenServer · ETS · monitors · tasks</i>"] --> Query
    Query["Query / Effects<br/><i>slicing · independence · taint · purity</i>"]
```

## Performance

Benchmarked on real projects (single-threaded, Apple M1 Pro):

| Project | Files | Functions | IR Nodes | Time | ms/file |
|---------|-------|-----------|----------|------|---------|
| ex_slop | 26 | 195 | 5,272 | 42ms | 1.6 |
| ex_dna | 32 | 346 | 10,787 | 108ms | 3.4 |
| Livebook | 72 | 940 | 22,507 | 192ms | 2.7 |
| Oban | 64 | 813 | 31,620 | 225ms | 3.5 |
| Keila | 190 | 1,394 | 49,674 | 361ms | 1.9 |
| Phoenix | 74 | 1,465 | 48,667 | 435ms | 5.9 |
| Absinthe | 282 | 2,276 | 69,281 | 477ms | 1.7 |

740 files, zero crashes.

## References

- Ferrante, Ottenstein, Warren — *The Program Dependence Graph and Its Use in
  Optimization* (1987)
- Horwitz, Reps, Binkley — *Interprocedural Slicing Using Dependence Graphs*
  (1990)
- Silva, Tamarit, Tomás — *System Dependence Graphs for Erlang Programs* (2012)
- Cooper, Harvey, Kennedy — *A Simple, Fast Dominance Algorithm* (2001)

## License

[MIT](LICENSE)
