# Changelog

## 1.1.0

### New

- **Plugin system** — `Reach.Plugin` behaviour for library-specific analysis.
  Auto-detects Phoenix, Ecto, Oban, GenStage, Jido, and OpenTelemetry at
  runtime. Override with `plugins:` option.
- **`mix reach` task** — generates self-contained interactive HTML report with
  three visualization modes: Control Flow, Call Graph, and Data Flow.
- **Expression-level control flow graph** — source-primary visualization where
  every line of every function is visible. Branch points (if/case/unless) show
  fan-out edges, all paths converge at merge points with blue converge edges.
- **Core CFG expansion** — `Reach.ControlFlow.build/1` now correctly expands
  branches nested inside pipes, assignments, and calls. `if ... end |> f()`
  shows both branches converging at the pipe call.
- **Intra-function data flow** — Data Flow tab shows variable def→use chains
  within each function, labeled with variable names.
- **Module preamble** — sidebar shows `use`/`import`/`alias`/`@attributes` as
  a collapsed header, not separate nodes.
- **Syntax highlighting** — Makeup-powered server-side highlighting in all
  code blocks, with proper indentation preservation via common-prefix dedent.
- **Multi-clause dispatch** — pattern-match dispatch nodes with colored
  clause edges for functions with multiple `def` heads.
- **6 built-in plugins**: Phoenix, Ecto, Oban, GenStage, Jido, OpenTelemetry.

### Improved

- **Call graph** — filtered Ecto query bindings, pipe operators, kernel ops,
  Ecto DSL macros; nil module resolved to detected module; deduplicated edges.
- **Text selection** — code blocks now allow text selection (`user-select: text`,
  nodes not draggable).
- **Sidebar navigation** — click scrolls and zooms to function, highlights all
  nodes of selected function with blue glow, dims others. Click background to
  clear.

### Fixed

- Crash on `key :start_line not found` when processing branch expressions.
- Node ID collisions in `Reach.Project` parallel file parsing (shared
  `:atomics` counter).
- Module name extraction fallback when path has no `lib/src` prefix.

## 1.0.0

First public release.

### Core analysis

- **Program Dependence Graph** — builds a graph capturing data and control
  dependencies for Elixir and Erlang source code. Every expression knows what
  it depends on and what depends on it.
- **Scope-aware data dependence** — variable definitions resolve through
  lexical scope chains. Variables in case clauses, fn bodies, and
  comprehensions don't leak to sibling scopes.
- **Binding role tracking** — pattern variables (`x` in `x = foo()`, `{a, b}`)
  are tagged as definitions at IR construction time. Data edges go from
  definition vars to use vars, not from clauses.
- **Match binding edges** — `z = x ++ y` creates `:match_binding` edges from
  the RHS expression to the LHS definition var, enabling transitive data flow
  through assignments.
- **Containment edges** — parent expressions depend on their child
  sub-expressions. `backward_slice(x + 1)` reaches both `x` and `1`.
- **Multi-clause function grouping** — `def foo(:a)` + `def foo(:b)` in the
  same module are merged into one function definition with proper dispatch
  control flow (`:clause_match` / `:clause_fail` edges).

### Three frontends

- **Elixir source** — `Reach.string_to_graph/2`, `Reach.file_to_graph/2`.
  Handles all Elixir constructs: match, case, cond, with/else, try/rescue/after,
  receive/timeout, for comprehensions, pipe chains (desugared), capture
  operators (`&fun/1`, `&Mod.fun/1`, `&(&1 + 1)`), `if`/`unless` (desugared
  to case), guards, anonymous functions, structs, maps, dot access on variables.
- **Erlang source** — `Reach.string_to_graph(source, language: :erlang)`,
  auto-detected for `.erl` files. Parses via `:epp`, translates Erlang abstract
  forms to the same IR.
- **BEAM bytecode** — `Reach.module_to_graph/2`, `Reach.compiled_to_graph/2`.
  Analyzes macro-expanded code from compiled `.beam` files. Sees `use GenServer`
  injected callbacks, macro-expanded `try/rescue`, generated functions.

### Slicing and queries

- `Reach.backward_slice/2` — what affects this expression?
- `Reach.forward_slice/2` — what does this expression affect?
- `Reach.chop/3` — nodes on all paths from A to B.
- `Reach.independent?/3` — can two expressions be safely reordered? Checks
  data flow (including descendant nodes), control dependencies, and side effect
  conflicts.
- `Reach.nodes/2` — filter nodes by `:type`, `:module`, `:function`, `:arity`.
- `Reach.neighbors/3` — direct neighbors with optional label filter.
- `Reach.data_flows?/3` — does data flow from source to sink? Checks
  descendant nodes of both source and sink.
- `Reach.depends?/3`, `Reach.has_dependents?/2`, `Reach.controls?/3`.
- `Reach.passes_through?/4` — does the flow path pass through a node matching
  a predicate?

### Taint analysis

- `Reach.taint_analysis/2` — declarative taint analysis with keyword filters
  (same format as `nodes/2`) or predicate functions. Returns source, sink,
  path, and whether sanitization was found.

### Dead code detection

- `Reach.dead_code/1` — finds pure expressions whose values are never used and
  don't contribute to any observable output (return values or side-effecting
  calls). Excludes module attributes, typespecs, and vars (compiler handles
  those).

### Effect classification

- `Reach.pure?/1`, `Reach.classify_effect/1` — classifies calls as `:pure`,
  `:io`, `:read`, `:write`, `:send`, `:receive`, `:exception`, `:nif`, or
  `:unknown`.
- Hardcoded database covers 30+ pure modules (Enum, Map, List, String, etc.)
  plus Erlang equivalents.
- `Enum.each` correctly classified as impure.
- **Type-aware inference** — functions not in the hardcoded database are
  auto-classified by extracting `@spec` via `Code.Typespec.fetch_specs`.
  Functions returning only data types are inferred as pure; functions returning
  `:ok` are left as unknown.

### Higher-order function resolution

- Auto-generated catalog of 1,000+ functions from pure modules where parameters
  flow to return value. Covers Enum, Stream, Map, String, List, Keyword, Tuple,
  and Erlang equivalents.
- `:higher_order` edges connect flowing arguments to call results.
- Impure functions (like `Enum.each`) excluded — their param flow is for side
  effects, not return value production.

### Interprocedural analysis

- **Call graph** — `{module, function, arity}` vertices with call edges.
- **System Dependence Graph** — per-function PDGs connected through `:call`,
  `:parameter_in`, `:parameter_out`, and `:summary` edges.
- **Context-sensitive slicing** — Horwitz-Reps-Binkley two-phase algorithm
  avoids impossible paths through call sites.
- **Cross-module resolution** — `Reach.Project` links call edges across
  modules and applies external dependency summaries.

### OTP awareness

- **GenServer state threading** — `:state_read` edges from callback state
  parameter to uses, `:state_pass` edges between consecutive callback returns.
- **Message content flow** — `send(pid, {:tag, data})` creates
  `{:message_content, :tag}` edges to `handle_info({:tag, payload})` pattern
  vars. Tags must match.
- **GenServer.call reply flow** — `{:reply, value, state}` creates
  `:call_reply` edges from reply value back to `GenServer.call` call site.
- **ETS dependencies** — `{:ets_dep, table}` edges between writes and reads
  on the same table, with table name tracking.
- **Process dictionary** — `{:pdict_dep, key}` edges between `Process.put`
  and `Process.get` on the same key.
- **Message ordering** — `:message_order` edges between sequential sends to
  the same target pid.

### Concurrency analysis

- **Process.monitor → :DOWN** — `:monitor_down` edges from monitor calls to
  `handle_info({:DOWN, ...})` handlers in the same module.
- **trap_exit → :EXIT** — `:trap_exit` edges from `Process.flag(:trap_exit)`
  to `handle_info({:EXIT, ...})` handlers.
- **spawn_link / Process.link** — `:link_exit` edges to `:EXIT` handlers.
- **Task.async → Task.await** — `:task_result` edges paired by module scope
  and position order.
- **Supervisor children** — `:startup_order` edges from child ordering in
  `init/1`.

### Multi-file project analysis

- `Reach.Project.from_sources/2`, `from_glob/2`, `from_mix_project/1` —
  parallel file parsing, cross-module call resolution, merged project graph.
- `Reach.Project.taint_analysis/2` — taint analysis across all modules.
- `Reach.Project.summarize_dependency/1` — compute param→return flow summaries
  for compiled dependency modules.

### Canonical ordering

- `Reach.canonical_order/2` — sorts block children so independent siblings
  have deterministic order regardless of source order. Dependent expressions
  preserve relative order. Enables Type IV reordering-equivalent clone
  detection in ExDNA.

### Integration

- `Reach.ast_to_graph/2` — build graph from pre-parsed Elixir AST (for
  Credo/ExDNA integration, no re-parsing).
- `Reach.to_graph/1` — returns the underlying `Graph.t()` (libgraph) for
  power users who need path finding, subgraphs, BFS/DFS, etc.
- `Reach.to_dot/1` — Graphviz DOT export.

### Performance

Benchmarked on real projects (Apple M1 Pro):

| Project | Files | Time |
|---------|-------|------|
| ex_slop | 26 | 36ms |
| ex_dna | 32 | 87ms |
| Livebook | 72 | 160ms |
| Oban | 64 | 195ms |
| Keila | 190 | 282ms |
| Phoenix | 74 | 333ms |
| Absinthe | 282 | 375ms |

740 files, zero crashes.
