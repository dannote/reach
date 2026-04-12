# ExPDG Query Language — Ecto-style Macros for Graph Queries

## Core idea

Ecto proved that **Elixir macros can be a query language**. You write what looks
like Elixir, but it compiles to a query plan that runs against a data store.

ExPDG does the same thing, but the data store is a **program dependence graph**
instead of a database.

```elixir
import ExPDG.Query

# "Find all definitions that have no data dependents and are pure"
from n in pdg,
  where: n.type == :definition,
  where: pure?(n),
  where: not has_dependents?(n, :data),
  select: n
```

This compiles at build time to an efficient graph traversal plan —
node filtering → edge walking → predicate checking — with no runtime
interpretation overhead.

---

## Why Ecto-style

| Property | Ecto | ExPDG |
|----------|------|-------|
| Looks like Elixir | ✓ | ✓ |
| Compiles to query plan | ✓ (SQL AST) | ✓ (traversal plan) |
| Composable | ✓ (subqueries, joins) | ✓ (subqueries, path composition) |
| Type-checkable | ✓ (schema) | ✓ (IR node types) |
| Escape hatch | ✓ (fragment) | ✓ (custom/1) |
| Zero new syntax to learn | ✓ | ✓ |
| Familiar to Elixir devs | very | very |

The Yargy DSL (defrule/defgrammar) is great for NLP where rules are
domain-specific grammar fragments. But for code analysis, the audience
is Elixir developers who already think in `from/where/select`. Meeting
them where they are beats inventing a new notation.

---

## Query primitives

### Node selectors

```elixir
# Select nodes by type
from n in pdg, where: n.type == :call
from n in pdg, where: n.type == :definition
from n in pdg, where: n.type == :pattern
from n in pdg, where: n.type == :literal

# Select by properties
from n in pdg, where: n.module == Ecto.Adapters.SQL
from n in pdg, where: n.function == :query
from n in pdg, where: n.arity == 2
from n in pdg, where: n.var == :user_input

# Select by effect
from n in pdg, where: pure?(n)
from n in pdg, where: effectful?(n, :io)
from n in pdg, where: effectful?(n, :ets_write)
from n in pdg, where: effectful?(n, :send)
```

### Edge / path predicates

```elixir
# Direct edges
from {a, b} in edges(pdg),
  where: a ~> b  # data dependence edge exists
from {a, b} in edges(pdg),
  where: a ~>> b  # control dependence edge exists

# Paths (transitive)
from {source, sink} in pdg,
  where: data_flows?(source, sink)          # data-dep path exists
from {source, sink} in pdg,
  where: controls?(source, sink)            # control-dep path exists
from {a, b} in pdg,
  where: depends?(a, b)                     # any dependence
from {a, b} in pdg,
  where: independent?(a, b)                 # no dependence either way

# Path constraints
from {source, sink} in pdg,
  where: data_flows?(source, sink),
  where: not passes_through?(source, sink, &sanitized?/1)
```

### Structural predicates

```elixir
from n in pdg, where: in_function?(n, {MyModule, :handle_call, 3})
from n in pdg, where: in_scope?(n, scope_id)
from {a, b} in pdg, where: same_pipe?(a, b)
from {a, b} in pdg, where: adjacent?(a, b)
from {a, b} in pdg, where: sibling_clauses?(a, b)
```

### OTP-aware predicates

```elixir
# GenServer
from n in pdg, where: genserver_state_read?(n)
from n in pdg, where: genserver_state_write?(n)
from {a, b} in pdg, where: state_flows?(a, b)  # through handle_* return

# Messages
from {send, recv} in pdg,
  where: send.type == :send_call,
  where: recv.type == :receive_clause,
  where: message_flows?(send, recv)

# ETS
from {w, r} in pdg,
  where: ets_write?(w),
  where: ets_read?(r),
  where: same_table?(w, r)

# Supervision
from {parent, child} in pdg,
  where: supervises?(parent, child)


```

---

## Composing queries

### Subqueries

```elixir
user_inputs = from n in pdg,
  where: n.type == :call,
  where: n.module == Plug.Conn,
  where: n.function in [:params, :query_params, :body_params]

sql_calls = from n in pdg,
  where: n.type == :call,
  where: n.module == Ecto.Adapters.SQL,
  where: n.function == :query

from {source, sink} in pdg,
  where: source in ^user_inputs,
  where: sink in ^sql_calls,
  where: data_flows?(source, sink),
  select: {source, sink}
```

### Named queries as building blocks

```elixir
defmodule MyAnalysis do
  import ExPDG.Query

  def taint_sources(pdg) do
    from n in pdg,
      where: n.type == :call,
      where: n.module == Plug.Conn,
      where: n.function in [:params, :query_params]
  end

  def dangerous_sinks(pdg) do
    from n in pdg,
      where: n.type == :call,
      where: {n.module, n.function} in [
        {System, :cmd},
        {Ecto.Adapters.SQL, :query},
        {Code, :eval_string}
      ]
  end

  def taint_violations(pdg) do
    from {source, sink} in pdg,
      where: source in ^taint_sources(pdg),
      where: sink in ^dangerous_sinks(pdg),
      where: data_flows?(source, sink),
      where: not passes_through?(source, sink, &sanitizer?/1),
      select: %{source: source, sink: sink, path: shortest_path(source, sink, :data)}
  end
end
```

---

## Defining rules (checks)

Rules are named queries with metadata — severity, message, category.
They integrate with Credo-style reporting.

```elixir
defmodule MyProject.Checks do
  use ExPDG.Check

  check :useless_expression,
    severity: :warning,
    category: :code_quality do
    from n in pdg,
      where: pure?(n),
      where: not returns?(n),
      where: not has_dependents?(n, :data),
      message: "Expression has no effect — result is unused and it's pure"
  end

  check :sql_injection,
    severity: :error,
    category: :security do
    from {source, sink} in pdg,
      where: source in ^taint_sources(pdg),
      where: sink in ^sql_sinks(pdg),
      where: data_flows?(source, sink),
      where: not passes_through?(source, sink, &sanitized?/1),
      message: "Unsanitized input flows from #{source.location} to #{sink.location}"
  end

  check :reorderable_pipe_stages,
    severity: :info,
    category: :readability do
    from {a, b} in pdg,
      where: same_pipe?(a, b),
      where: adjacent?(a, b),
      where: independent?(a, b),
      where: pure?(a),
      where: pure?(b),
      message: "Pipe stages at #{a.location} and #{b.location} are independent"
  end

  check :genserver_state_leak,
    severity: :warning,
    category: :otp do
    from {read, response} in pdg,
      where: genserver_state_read?(read),
      where: in_callback?(read, :handle_call),
      where: data_flows?(read, response),
      where: response.type == :reply_value,
      where: not passes_through?(read, response, &deep_copy?/1),
      message: "GenServer state reference leaks to caller — consider deep copying"
  end

  check :ets_race_condition,
    severity: :warning,
    category: :concurrency do
    from {read, write} in pdg,
      where: ets_read?(read),
      where: ets_write?(write),
      where: same_table?(read, write),
      where: not same_transaction?(read, write),
      where: data_flows?(read, write),
      message: "ETS read-then-write without atomicity — possible race condition"
  end
end
```

---

## Escape hatch

When the macro DSL can't express something, use `custom/1`:

```elixir
check :complex_dependency_chain,
  severity: :info,
  category: :complexity do
  from n in pdg,
    where: custom(fn pdg, n ->
      slice = ExPDG.backward_slice(pdg, n)
      length(slice) > 50
    end),
    message: "Expression depends on #{length(slice)} other expressions"
end
```

Or skip the macro entirely and implement `ExPDG.Check` behaviour directly:

```elixir
defmodule MyProject.Checks.WeirdOne do
  @behaviour ExPDG.Check

  @impl true
  def run(pdg, _opts) do
    # full Elixir, full API access, no restrictions
    for node <- ExPDG.nodes(pdg),
        ExPDG.backward_slice(pdg, node) |> length() > 100 do
      %ExPDG.Diagnostic{
        severity: :info,
        location: node.source_span,
        message: "Overly complex dependency chain"
      }
    end
  end
end
```

---

## Compilation strategy

```
check :rule_name do                          ← Elixir macro
  from n in pdg, where: ..., select: ...
end
    │
    ▼  (compile time)
%QueryPlan{
  entry_filter: fn node -> node.type == :call end,    ← which nodes to start from
  edge_walks: [:data, :forward, 3],                    ← which edges to traverse
  predicates: [&pure?/1, ...],                         ← what to check
  select: :node                                        ← what to return
}
    │
    ▼  (runtime — per PDG)
[%Diagnostic{}, ...]                                   ← results
```

### Optimizations the compiler can do

1. **Start node selection**: if `where: n.type == :call and n.module == Foo`,
   only iterate call nodes to `Foo` — don't scan the whole graph

2. **Edge filtering**: if only data edges matter, skip control edges in traversal

3. **Short-circuit**: if `where: not has_dependents?(n, :data)`, check
   out-degree first before any path traversal

4. **Rule batching**: multiple checks that start from `n.type == :call`
   share the initial scan

5. **Slice caching**: backward/forward slices are memoized per PDG build —
   multiple rules reuse them

---

## Built-in check library

Ship out of the box (like Credo ships checks):

### Code quality
| Check | What it finds |
|-------|---------------|
| `useless_expression` | Pure expression with unused result |
| `unused_definition` | Variable defined, never used |
| `dead_code` | Unreachable after guaranteed return/raise |
| `redundant_guard` | Guard implied by control context |
| `reorderable_statements` | Independent statements, could group better |
| `unnecessary_assignment` | `x = expr; x` → just `expr` |

### Security
| Check | What it finds |
|-------|---------------|
| `sql_injection` | Unsanitized input reaches query |
| `command_injection` | User input reaches System.cmd |
| `log_sensitive_data` | Secret/password flows to Logger |
| `open_redirect` | User input flows to redirect URL |
| `eval_injection` | User input reaches Code.eval_string |

### OTP
| Check | What it finds |
|-------|---------------|
| `genserver_state_leak` | State reference escapes to caller |
| `genserver_bottleneck` | Long sync call chain through single GenServer |
| `ets_race_condition` | Non-atomic read-then-write |
| `supervisor_circular_dep` | Circular startup dependencies |
| `unused_handle_info` | handle_info clause that nothing sends to |
| `process_dict_leak` | Process dictionary used across module boundaries |

### Complexity
| Check | What it finds |
|-------|---------------|
| `deep_dependency_chain` | Backward slice exceeds threshold |
| `high_fan_in` | Many callers (fragile function) |
| `high_fan_out` | Depends on many things (coupled function) |
| `god_function` | Function with too many data/control deps |

---

## Relationship to Credo

ExPDG checks are **not a Credo replacement** — they're a complement.

Credo checks operate on AST (syntax). ExPDG checks operate on PDG (semantics).

Examples Credo can't do but ExPDG can:
- "Is this expression reachable?" (needs CFG)
- "Does user input reach this sink?" (needs data flow)
- "Are these two statements independent?" (needs PDG)
- "Does this GenServer state leak?" (needs OTP model + data flow)

Potential integration:
- ExPDG ships a Credo plugin that registers ExPDG checks as Credo checks
- Credo runs them alongside its own checks
- Same `mix credo` interface, deeper analysis underneath
