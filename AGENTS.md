# Reach — Agent Guidelines

This repository is part of the Elixir Vibe organization.

## Architecture

Reach builds a Program Dependence Graph from Elixir/Erlang source code and visualizes it as interactive HTML reports with three views: Control Flow, Call Graph, Data Flow.

Key modules:
- `Reach.Frontend.Elixir` — AST → IR translation
- `Reach.ControlFlow` — IR → CFG (per-function DAG, never cyclic)
- `Reach.Dominator` — immediate dominator/post-dominator, dominator tree, dominance frontier
- `Reach.Effects` — per-call side-effect classification (pure/io/read/write/send/exception/nif/unknown)
- `Reach.Visualize.ControlFlow` — CFG → visualization blocks/edges
- `Reach.Visualize.Helpers` — source extraction, pattern rendering, line helpers
- `assets/js/components/ReachGraph.vue` — frontend (Vue Flow + ELK layout)

## Block Quality Acceptance Criteria

Every change to visualization code MUST maintain these invariants, tested across real codebases (Elixir, Phoenix, Ecto, Oban, Plausible, Livebook — 16k+ functions).

### Coverage
1. Every source line of the function body appears in exactly one block. Entry = def line, exit = end line. Allow ≤5 missing lines per function (compiler limitation with pipe chains and heredocs).

### Disjointness
2. No two blocks share the same source line range. Block end_line is clamped to `min(raw_end, min_next_start - 1)` across ALL blocks, not just the next one in traversal order. Block end_line uses `Enum.max` across all vertex end_lines in the block (earlier vertices can have wider ranges than the last one).

### Branch Boundaries
3. Every branch point (case/if/cond/receive/try/with) creates a new block.
4. Every clause is its own block.
5. Anonymous fn bodies are decomposed — `Enum.reduce(fn ... end)` callbacks with internal branching get split into blocks. Multi-clause `fn` dispatches like `case`.

### Block Content
6. No empty blocks — every block has `source_html`. Clauses with no compiler source spans show the pattern label as fallback.
7. No nil labels — every block has a meaningful label.

### Structural
8. Entry block = function signature. Exit block = function end. Exit must be connected via edges (use `find_exit_predecessors`).
9. Sequential chains on distinct lines merge into one block.
10. Same-line nested constructs stay separate — merge only when there's a single branch winner on the line.

### Edge Correctness
11. Every edge maps to a real CFG path.
12. Multi-clause functions show dispatch → clause edges with pattern labels.

### No Duplicate Lines
13. No source line appears in more than one block (except def/end lines shared by entry/exit).

## Multi-clause Functions

Multi-clause functions with bodies use `build_multi_clause_cfg` — the CFG includes clause nodes as vertices (normally filtered out), dispatch edges from entry to each clause block, and full CFG decomposition inside each clause body. Pure pattern dispatches (all clauses ≤2 children) go through the normal single-function CFG path.

## Testing Changes

Run the block quality test: `mix test test/visualize/block_quality_test.exs`

Smoke test across real codebases — clone first if needed:
```bash
for repo in elixir-lang/elixir phoenixframework/phoenix elixir-ecto/ecto oban-bg/oban; do
  name=$(basename $repo)
  [ -d /tmp/$name ] || git clone --depth 1 https://github.com/$repo /tmp/$name
done
```
```elixir
dirs = ["/tmp/phoenix/lib", "/tmp/ecto/lib", "/tmp/oban/lib", "/tmp/elixir/lib"]
# Check: zero crashes on to_json, verify block quality metrics
```

## CLI Commands

Analysis commands (all support `--format text|json|oneline`):

| Command | Purpose |
|---|---|
| `mix reach` | Interactive HTML report with CFG/call graph/data flow views |
| `mix reach.modules` | Module listing with complexity metrics |
| `mix reach.coupling` | Module-level coupling (afferent/efferent/instability/circular deps) |
| `mix reach.hotspots` | Functions ranked by complexity × callers (refactoring targets) |
| `mix reach.depth` | Functions ranked by dominator tree depth (control nesting) |
| `mix reach.effects` | Effect classification distribution and unknown-effect calls |
| `mix reach.impact` | Change impact for a specific function (callers, return deps) |
| `mix reach.deps` | Function dependencies (callers, callees, shared state) |
| `mix reach.dead_code` | Unused pure expressions |
| `mix reach.smell` | Pipeline waste, redundant computation, eager patterns |
| `mix reach.flow` | Data flow / taint tracing (--from/--to or --variable) |
| `mix reach.slice` | Program slicing (backward/forward from a line) |
| `mix reach.graph` | Terminal CFG rendering (requires boxart) |
| `mix reach.xref` | Cross-function data flow (parameter, return, state edges) |
| `mix reach.concurrency` | Task/monitor/spawn patterns and supervisor topology |
| `mix reach.boundaries` | Functions with multiple distinct side effects |
| `mix reach.otp` | GenServer state machines, ETS/process-dict coupling, missing handlers |

## What NOT to Do

- Don't use string matching to extract source constructs (use the parsed AST/IR)
- Don't merge same-line blocks when multiple branch vertices share the line
- Don't take block end_line from only the last vertex — use max across all
- Don't filter out clause nodes from the CFG for multi-clause functions
- Don't create exit nodes without connecting them via edges
