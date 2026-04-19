# Changelog

## Unreleased

### New

- **4 analysis commands** for codebase-level insights:
  - `mix reach.coupling` — module-level coupling metrics (afferent/efferent
    coupling, Martin's instability metric, circular dependency detection).
    `--graph` renders the module dependency graph via boxart.
  - `mix reach.hotspots` — functions ranked by complexity × caller count,
    surfacing the highest-risk refactoring targets.
  - `mix reach.depth` — functions ranked by dominator tree depth (control
    flow nesting). `--graph` renders the CFG of the deepest function.
  - `mix reach.effects` — effect classification distribution across the
    codebase and top unclassified calls. `--module` restricts to one module.

### Improved

- **Field access detection** — `socket.assigns`, `conn.params`, `state.count`
  are now recognized as field access (`kind: :field_access`) instead of
  remote calls with a fake module name. Classified as `:pure`.
- **Compile-time noise filtering** — `@doc`, `@spec`, `@type`, `use`,
  `import`, `alias`, `require`, `::`, `__aliases__` and other compile-time
  constructs are now classified as `:pure` instead of `:unknown`.
- Unknown call ratio dropped from ~89% to ~46% across real codebases
  (Plausible, Livebook, Ecto, Oban).
- Upgraded boxart to 0.3.1.

## 1.4.1

### Fixed

- `mix reach.modules`, `mix reach.impact`, and `mix reach.slice` crash with
  `BadBooleanError` when `--graph` is not passed (closes #6).

## 1.4.0

### New

- **Terminal graph rendering** via optional `boxart` dependency:
  - `mix reach.graph Mod.fun/arity` — control flow graph with syntax-highlighted
    source code and line numbers in each node
  - `mix reach.graph Mod.fun/arity --call-graph` — callee tree as mindmap
  - `mix reach.deps Mod.fun/arity --graph` — callee tree visualization
  - `mix reach.impact Mod.fun/arity --graph` — caller tree visualization
  - `mix reach.modules --graph` — module dependency graph (internal only)
  - `mix reach.otp --graph` — GenServer state diagrams per module
  - `mix reach.slice file:line --graph` — slice subgraph

### Improved

- CFG rendering reuses `Visualize.ControlFlow.build_function/2` — same
  line ranges, block merging, and source extraction as the HTML visualization
- Graph output clamped to terminal width via `Boxart.render max_width`
- CFG code blocks dedented to match HTML visualization indentation
- Same-line CFG vertices merged (no more duplicate nodes)

## 1.3.0

### New

- **8 mix tasks for code analysis** — agent-oriented CLI tools that expose
  Reach's graph analysis as structured text/JSON output:
  - `mix reach.modules` — bird's-eye codebase inventory sorted by
    name/functions/complexity, with OTP/LiveView behaviour detection
  - `mix reach.dead_code` — find unused pure expressions (parallel per-file)
  - `mix reach.deps` — direct callers, callee tree, shared state writers
  - `mix reach.impact` — transitive callers, return value dependents, risk
  - `mix reach.flow` — taint analysis (`--from`/`--to`) and variable tracing
  - `mix reach.slice` — backward/forward program slicing by file:line
  - `mix reach.otp` — GenServer state machines, ETS/process dictionary
    coupling, missing message handlers, supervision tree
  - `mix reach.smell` — cross-function performance anti-patterns (redundant
    traversals, duplicate computations, eager patterns)
  - All tools support `--format text` (colored), `json`, and `oneline`
- **Dynamic dispatch in Elixir frontend** — `handler.(args)` and `fun.(args)`
  now emit `:call` nodes with `kind: :dynamic` (closes #4)
- **ANSI color output** — headers cyan, function names bright, file paths
  faint, complexity colored by severity, OTP state actions colored by type.
  Auto-disabled when piped.

### Fixed

- **BEAM frontend source_span normalization** — `:erl_anno` annotations
  (integer, `{line, col}` tuple, keyword list, or nil) now normalized via
  `:erl_anno.line/1` and `:erl_anno.column/1`. `start_line` is always integer
  or nil. Column info extracted from `{line, col}` tuples (closes #5).
- **Visualization crash on BEAM modules** — `build_def_line_map` and
  `cached_file_lines` now skip non-source files and validate UTF-8.
- **dead_code false positives reduced 91%** (628 → 58 on Phoenix) —
  fixed-point alive expansion for intermediate variables, branch-tail return
  tracing through case/cond/try/fn, guard exclusion, comprehension
  generator/filter exclusion, cond condition exclusion, `<>` pattern
  recognition, impure module blocklist (`Process`, `:code`, `:ets`, `Node`,
  `System`, etc.), typespec exclusion, impure call descendant marking.
- **reach.smell false positives** — structural pipe check instead of
  transitive graph reachability, per-clause redundant computation grouping,
  full argument comparison (vars + literals), type-check function exclusion,
  function reference filtering, callback purity check for map→map fusion.
- **reach.otp state detection** — finds struct field access (`state.field`),
  unwraps `%State{} = state` patterns, detects ETS writes through state
  parameter. No longer flags `Map.merge` on non-state variables.
- **reach.deps** shows only direct callers (transitive analysis in
  reach.impact).
- **Block quality** — `compute_vertex_ranges` uses `min_line_in_subtree` to
  include multi-line pattern children.

### Improved

- **Performance** — effect classification cached in ETS (shared across
  parallel tasks), SDG construction parallelized across modules.
  Livebook analysis: 9.7s → 3.5s.
- **Consistent CLI output** — `(none found)` everywhere, descriptive match
  descriptions (`name = Module.func is unused`), empty slice suggests
  `--forward`, zero-function modules filtered from reach.modules.

## 1.2.0

### New

- **Gleam support** — analyze `.gleam` source files with accurate line mapping.
  Uses the `glance` parser (Gleam’s own parser, written in Gleam) for native AST
  parsing with byte-offset spans. Supports case expressions, pattern matching with
  guards, pipes, anonymous functions, record updates, and all standard Gleam
  constructs. Requires `gleam build` and glance on the code path.

### Fixed

- Unreachable `block_label/5` catch-all clause removed (Dialyzer).
- `file_to_graph/2` cyclomatic complexity reduced — extracted `parse_file_and_build/3`
  and `read_and_build_elixir/2`.
- `func_end_line/2` simplified — extracted `find_nearest_end/2`.
- `apply/3` used for optional `:glance` module to avoid compile-time warnings.
- Empty blocks from line clamping filtered out in visualization.
- Exit nodes show label in Vue component (no more invisible gray bars).
- Block end_line uses max across all vertices (fixes multi-line heredoc coverage).
- Block overlap elimination — end_line clamping considers all blocks globally.
- `repo_module?/1` crash on capture syntax `& &1.name` (closes #3).

## 1.1.3

### Fixed

- Crash in `Reach.Plugins.Ecto.repo_module?/1` on capture syntax like
  `& &1.name` where call meta contains AST tuples instead of atoms (closes #3).
- Block end_line now uses max across all vertices in the block, fixing missing
  coverage for multi-line heredoc strings inside if/case branches.
- Block overlap elimination — end_line clamping now considers all blocks
  globally, not just the next one in traversal order (155 → 0 overlaps).
- Multi-clause dispatch functions now connect exit nodes via
  `find_exit_predecessors` instead of leaving them disconnected.

### Audited

16,047 functions across 1,213 files (Elixir, Phoenix, Ecto, Oban, Plausible,
Livebook): 0 empty blocks, 0 nil labels, 0 overlaps, 0 duplicate lines,
0 missing exits, 0 disconnected exits.

## 1.1.2

### Fixed

- **Anonymous fn bodies inlined into parent CFG** — `Enum.reduce(fn ... end)`
  callbacks with internal branching (case/if/raise) are now decomposed into
  visible control flow blocks instead of being opaque single nodes.
- **Block merging for same-line nested constructs** — inline `if x, do: a, else: b`
  no longer creates monster merged blocks like `b_1490_1485_1489_1478`.
  Branch detection now includes clause targets and multi-out vertices.
- **Source extraction for clauses without source spans** — multi-clause function
  heads (e.g. `def foo(:join, :inner)`) that lack compiler source spans now show
  source code via child node line walking instead of empty gray blocks.
- **Block disjointness** — overlapping blocks eliminated (533 → 0) by clamping
  block end_line to `(next_block_start - 1)` and removing duplicate line ranges
  from dispatch clause blocks.
- **Missing exit nodes** — multi-clause dispatch functions now include proper
  exit nodes (58 missing → 0).
- **Pure pattern-matching dispatches** — functions like `join_qual/1` with 9
  one-line clauses render as a single function node instead of a useless
  dispatch → 9 disconnected clause blocks.
- **Preamble/sidebar spam removed** — the sidebar no longer shows `@doc`,
  `@moduledoc`, `use`, `import` lines extracted by string matching. Sidebar
  shows only module name and function list.
- **Render patterns** added for `:pin`, `:binary_op`, `:unary_op`, `:cons`,
  `:guard`, `:generator`, `:filter`, `:module_def` node types.

### Added

- **Block quality audit test** — validates 6 acceptance criteria (coverage,
  disjointness, no empty blocks, no nil labels, entry/exit structure) across
  real codebases (Ecto, Phoenix, Oban).

## 1.1.1

### Fixed

- Crash (`FunctionClauseError`) on macro definitions that look like `if/unless`
  calls with non-keyword-list branches (e.g. `defmacro if(condition, clauses)`
  in Elixir's own `Kernel`).
- Crash when `case/cond/receive` do-blocks contain `unquote` splices instead
  of a normal clause list (macro-heavy code like `Macro`, `ExUnit.Callbacks`).
- `hd([])` crash in control-flow builder on code with empty exit sets
  (e.g. single-clause `cond do true -> :ok end`).
- Struct/map pattern rendering crash with field bindings (from PR #2).

### Tested

Smoke-tested on 3,024 files across 8 major Elixir projects with zero failures:
elixir, phoenix, ecto, oban, plausible, livebook, blockscout, firezone.

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
- **Core CFG expansion** — Reach.ControlFlow.build/1 now correctly expands
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
