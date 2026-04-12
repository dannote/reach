# ExPDG — Program Dependence Graph for BEAM Languages

## Vision

A **program dependence graph** for BEAM languages — the foundation layer that
makes deep static analysis possible.

A PDG captures **what depends on what** in a program: which expressions
produce values consumed by others (data dependence), and which expressions
control whether others execute (control dependence). Once you have that graph,
a huge class of analyses becomes graph queries instead of bespoke implementations.

### What it enables

**Linter / code quality rules:**
- unused variable on specific branch (not just "anywhere in function")
- expression with no effect (result unused, no side effects)
- redundant condition (already guaranteed by control context)
- reorderable statements (better readability / grouping)
- shadowed binding that is never reached

**Security / taint analysis:**
- does user input reach SQL/shell/eval without sanitization?
- does secret data flow to logs/responses?
- which functions can influence authentication decisions?

**Refactoring:**
- is it safe to extract this block into a function? (what are its inputs/outputs?)
- can these two independent blocks be parallelized?
- what is the minimal set of code affected by this change? (impact analysis)

**Clone detection (ExDNA integration):**
- reordering-equivalent clones: `a |> b |> c` ≡ `a |> c |> b` when `b` and `c` are independent
- semantically equivalent clones with different variable names and structure

**Dead code:**
- unreachable code after guaranteed return/raise
- pure expression whose result is never used
- function that nothing calls (with SDG)

**Program comprehension:**
- backward slice: "what affects this line?"
- forward slice: "what does this line affect?"
- chop: "how does A influence B?"

**Bug detection:**
- variable potentially uninitialized on some path
- pattern match that can't fail but has a catch-all eating errors
- exception that silently swallows important state changes

The PDG is not the end product — it's the **infrastructure** that makes all
of these tractable. Individual analyses are built on top as queries.

---

## Architecture Overview

```
Source (.ex/.erl)
    │
    ▼
┌──────────────┐
│  Frontend    │  epp → erl_scan → erl_parse → erl_syntax
│  + IR Build  │  Elixir: Code.string_to_quoted → normalize
└──────┬───────┘
       │
       ▼
┌──────────────┐
│  CFG Builder │  Control Flow Graph per function
└──────┬───────┘
       │
       ▼
┌──────────────┐
│  Dominators  │  Dominator tree, post-dominator tree
│  + Frontiers │  Dominance frontier, reverse dominance frontier
└──────┬───────┘
       │
       ▼
┌──────────────┐
│  CDG Builder │  Control Dependence Graph
└──────┬───────┘
       │
       ▼
┌──────────────┐
│  DDG Builder │  Data Dependence Graph (reaching defs, def-use)
└──────┬───────┘
       │
       ▼
┌──────────────┐
│  PDG         │  CDG ∪ DDG = Program Dependence Graph
└──────┬───────┘
       │
       ▼
┌──────────────┐
│  SDG         │  Interprocedural: call/summary edges
└──────┬───────┘
       │
       ▼
┌──────────────┐
│  Queries     │  Slicing, reachability, independence checks
└──────────────┘
```

---

## Phase 0 — Project Setup

### Deliverables
- Mix project with `mix new ex_pdg`
- CI with `mix test`, `mix credo`, `mix dialyzer`
- Property-based testing dependency (StreamData)
- Graph storage via `:digraph` / `:digraph_utils` (or `libgraph` if immutability preferred)
- Documentation skeleton

### Key decisions

#### Expression-oriented IR, not statement-oriented
Classic PDGs use statements as nodes. BEAM languages are expression-oriented.
Follow the EDG approach (Silva, Tamarit, Galindo — UPV):
every node is an expression or sub-expression.

#### Elixir-first, Erlang-compatible
- Primary target: Elixir AST (`Code.string_to_quoted`)
- Secondary: Erlang abstract forms via `epp`/`erl_parse`
- Shared IR that both frontends emit into

#### `:digraph` for mutable graph during construction, export to immutable for queries
OTP's `:digraph` is fast for building. Convert to `libgraph` or plain maps for
query/serialization.

---

## Phase 1 — IR + CFG

**Goal:** Parse Elixir source → internal IR → control flow graph.

### 1.1 Internal IR

Each IR node needs:
- `id` — unique, stable identifier
- `type` — expression kind (`:call`, `:match`, `:case`, `:guard`, `:literal`, `:var`, `:block`, `:fn`, `:try`, `:receive`, `:comprehension`, `:pipe`, etc.)
- `source_span` — `{file, start_line, start_col, end_line, end_col}`
- `children` — ordered sub-expressions
- `scope` — lexical scope id
- `bindings` — variables defined/used (populated later)
- `effects` — purity classification (populated later)

Design note: keep IR close to source structure. Don't lower too aggressively —
the whole point is source-level analysis for tooling.

### 1.2 Elixir Frontend

```
source string
  → Code.string_to_quoted(source, columns: true, token_metadata: true)
  → Macro.prewalk to normalize
  → IR nodes
```

Normalization:
- desugar `|>` into nested calls
- desugar `with` into nested case
- desugar `for` into `:comprehension` node
- expand `if`/`unless`/`cond` into `:case` nodes
- keep `try`/`receive` as-is (they have real control flow)
- keep guards separate from body
- represent multi-clause `def` as dispatch node + clause nodes

### 1.3 Erlang Frontend (optional, Phase 1b)

```
source file
  → :epp.parse_file(file, [])
  → :erl_syntax.form_list(forms)
  → walk with :erl_syntax_lib
  → IR nodes
```

### 1.4 CFG Construction

For each function definition, build a CFG where:
- nodes are IR expression nodes (or basic blocks of sequential expressions)
- edges are control flow transitions

#### Edge types
- `:sequential` — normal fall-through
- `:true_branch` / `:false_branch` — conditional
- `:clause_match` / `:clause_fail` — pattern match success/failure
- `:guard_success` / `:guard_fail` — guard evaluation
- `:exception` — throw/error/exit
- `:catch` — exception handler entry
- `:after` — finally/after block
- `:timeout` — receive timeout branch
- `:return` — function exit

#### Special cases
- **Multiple clauses**: each clause is a separate entry; clause failure falls through to next clause
- **Guards**: separate guard CFG; guard failure → next clause
- **`case`/`cond`**: branch per clause, same as above
- **`try`**: normal path + exception paths + after path
- **`receive`**: message match clauses + timeout clause
- **`with`**: success chain + else clauses
- **Recursion**: self-call edge (not a back-edge in the traditional loop sense, but important for analysis)
- **Pipe chains**: desugared into nested calls, CFG is sequential
- **Comprehensions**: generator + filter + body, with implicit iteration

#### Synthetic nodes
- `ENTRY` — function entry point
- `EXIT` — function exit (may be multiple: normal return, exception, etc.)

### 1.5 Tests for Phase 1

#### CFG correctness tests
```
test "straight-line code has linear CFG"
test "if/else creates diamond CFG"
test "case with 3 clauses creates 3-branch CFG"
test "guard failure falls to next clause"
test "try/catch creates normal + exception paths"
test "try/after connects to after block from all paths"
test "receive with timeout creates timeout branch"
test "nested case creates nested branches"
test "pipe chain is sequential after desugaring"
test "multi-clause function creates dispatch CFG"
test "comprehension has generator → filter → body loop"
test "with/else creates chain + fallback branches"
```

#### IR round-trip tests
```
test "IR preserves source spans"
test "IR preserves variable names"
test "desugared pipe recovers original call chain"
```

### Stealable references
- **e-Knife** (UPV GitLab): expression-level CFG for Erlang, closest language match
- **Joern CfgCreator**: tree-sitter → CFG algorithm, adaptable pattern
- **angr CDG**: clean postdom-based approach (Python, readable)

---

## Phase 2 — Dominators + Control Dependence

**Goal:** Post-dominator tree → CDG.

### 2.1 Dominator / Post-dominator Trees

Algorithm: **Lengauer-Tarjan** (O(N α(N)), practically linear).

Implementation plan:
1. Reverse the CFG (flip all edges)
2. Run dominator computation on reversed CFG → post-dominator tree
3. Also compute forward dominator tree (useful for some analyses)

The dominator algorithm is language-agnostic. This is pure graph theory.

### 2.2 Dominance Frontier

For each node `n`, its dominance frontier `DF(n)` is the set of nodes where
`n`'s dominance ends. The **reverse dominance frontier** on the post-dominator
tree gives us control dependence.

### 2.3 CDG Construction

Ferrante et al. (1987) algorithm:

```
For each CFG edge (A, B):
  if B does not post-dominate A:
    walk up post-dominator tree from B
    until we reach A's immediate post-dominator (exclusive)
    mark each visited node as control-dependent on A
    label the edge with the branch condition (true/false/clause-N/guard/exception/timeout)
```

#### CDG edge labels for BEAM
- `{:branch, :true}` / `{:branch, :false}`
- `{:clause, index}` — which clause matched
- `{:guard, :success}` / `{:guard, :failure}`
- `{:exception, type}` — catch/rescue path
- `{:timeout}` — receive timeout
- `{:entry}` — control-dependent on function entry (always executes)

### 2.4 Tests for Phase 2

#### Post-dominator tests (hand-built CFGs)
```
test "linear CFG: each node post-dominated by successor"
test "diamond: join node post-dominates both branches"
test "early return: exit post-dominates return, not subsequent code"
test "try/catch: after block post-dominates all paths"
test "multiple exits: EXIT post-dominates all real exits"
test "receive timeout: neither clause post-dominates the other"
```

#### CDG tests
```
test "if/else: both branches control-dependent on condition"
test "code after if: control-dependent on ENTRY, not on condition"
test "case clause body: control-dependent on case head with clause label"
test "guard body: control-dependent on guard with success label"
test "try body: control-dependent on ENTRY"
test "catch body: control-dependent on try with exception label"
test "nested if: inner branches dependent on outer condition too"
test "unconditional code: dependent only on ENTRY"
```

### Stealable references
- **LLVM PostDominators.cpp**: battle-tested Lengauer-Tarjan (Apache-2.0)
- **angr `compute_dominance_frontier`**: clean Python implementation
- **grammarware/pdg Post Dominator Tree module**: Rascal, has unit tests
- **Ferrante et al. 1987 paper**: the canonical CDG algorithm

---

## Phase 3 — Data Dependence

**Goal:** Reaching definitions → def-use chains → DDG.

### 3.1 Variable Binding Analysis

Before data flow, we need to know what each expression defines and uses.

For BEAM languages:
- **Definitions**: `=` match, function parameters, `<-` generators, `rescue` bindings, comprehension variables
- **Uses**: variable references in expressions
- **Scope rules**: clause-local bindings, comprehension-local bindings, `fn` closures

Single assignment helps: each variable is defined exactly once in its scope.
But pattern matching creates simultaneous definitions:
```elixir
{a, b} = foo()  # defines both a and b from one expression
```

And guards can't define, only use.

Use `erl_syntax_lib.annotate_bindings/1` or `erl_syntax_lib.variables/1` as
starting points for Erlang forms. For Elixir AST, walk with `Macro.prewalk`
tracking scope.

### 3.2 Reaching Definitions

Classic iterative fixpoint dataflow:

```
for each block B:
  GEN[B] = definitions created in B
  KILL[B] = definitions killed (same variable redefined) in B

repeat until stable:
  for each block B:
    IN[B] = ∪ { OUT[P] | P is predecessor of B }
    OUT[B] = GEN[B] ∪ (IN[B] - KILL[B])
```

For single-assignment languages, KILL sets are simpler (only across clause boundaries and scope exits).

### 3.3 Def-Use Edges (DDG)

For each use of variable `v` at node `n`:
- find all reaching definitions of `v` at `n`
- add DDG edge from each definition to `n`, labeled with variable name

#### Additional data dependence edges for BEAM
- **Pattern component dependence**: `{a, b} = expr` creates edges from `expr` to both `a` and `b`
- **Map/record field dependence**: `%{key: val} = expr` — `val` depends on `expr` via field `:key`
- **Pipe value flow**: `a |> b |> c` — result of `a` flows to first arg of `b`, result of `b` flows to first arg of `c`
- **Comprehension flow**: generator result flows to body; filter result controls body execution
- **Return value flow**: last expression result is the return value

### 3.4 Tests for Phase 3

#### Reaching definitions
```
test "simple assignment reaches subsequent use"
test "pattern match defines multiple variables"
test "case clause variable doesn't leak to other clauses"
test "comprehension variable is local to comprehension"
test "function parameter reaches entire body"
test "variable in guard is use-only"
test "try variable doesn't reach catch clause"
test "with clause variable reaches next clause"
test "pin operator is a use, not a definition"
```

#### DDG edge tests
```
test "x = 1; y = x + 1 → edge from x=1 to x+1"
test "{a, b} = foo() → edges from foo() to both a and b"
test "pipe chain a |> b |> c → value flows through"
test "case result depends on matched clause body"
test "no edge between independent variables"
test "map update %{m | key: val} depends on both m and val"
test "comprehension body depends on generator variable"
```

### Stealable references
- **mchalupa/dg**: DDG construction for LLVM, generic approach
- **grammarware/pdg DDG module**: Rascal, unit-tested
- **e-Knife flow/value edges**: expression-level data dependence for Erlang
- **`erl_syntax_lib.annotate_bindings/1`**: OTP's own binding analysis

---

## Phase 4 — PDG Assembly + Independence Queries

**Goal:** Merge CDG + DDG → PDG. Answer "are X and Y independent?"

### 4.1 PDG Construction

```
PDG = CDG ∪ DDG
```

Each edge has:
- `type`: `:control` or `:data`
- `label`: branch condition or variable name
- `source` / `target`: IR node ids

Store in `:digraph` during construction. The PDG for a function is a single
directed graph with two kinds of edges.

### 4.2 Independence Query

Two expressions `X` and `Y` are **independent** if:
1. There is no data-dependence path from `X` to `Y` or `Y` to `X`
2. They have the same control dependencies (execute under the same conditions)
3. Neither has effects that conflict with the other

```elixir
def independent?(pdg, node_x, node_y) do
  not reachable?(pdg, node_x, node_y, :data) and
  not reachable?(pdg, node_y, node_x, :data) and
  same_control_deps?(pdg, node_x, node_y) and
  not conflicting_effects?(node_x, node_y)
end
```

This is the core primitive that enables reordering-aware clone detection.

### 4.3 Effect Annotations

Each IR node gets an effect classification:
- `:pure` — no side effects, no dependencies on mutable state
- `:read` — reads mutable state (ETS, process dict, etc.)
- `:write` — writes mutable state
- `:io` — performs IO
- `:send` — sends a message
- `:receive` — receives a message
- `:exception` — may raise
- `:nif` — calls a NIF (unknown effects)
- `:unknown` — can't determine

Conservative default: `:unknown` (treat as dependent on everything).

Build a known-pure function database:
- all of `Enum`, `Map`, `Keyword`, `List`, `String`, `Tuple`, `Kernel` arithmetic/comparison
- pure functions from `:erlang`, `:lists`, `:maps`, etc.
- user-annotated functions (`@pure true` or similar)

Two expressions with effects conflict if:
- both write to overlapping state
- one writes and the other reads overlapping state
- one sends and the other receives (same process)
- either has `:unknown` effects (conservative)

### 4.4 Slice Operations

```elixir
# Backward slice: everything that affects node N
backward_slice(pdg, n) = reachable(pdg, [n], :backward)

# Forward slice: everything affected by node N
forward_slice(pdg, n) = reachable(pdg, [n], :forward)

# Chop: intersection of forward from A and backward from B
chop(pdg, a, b) = forward_slice(pdg, a) ∩ backward_slice(pdg, b)
```

Use `:digraph_utils.reaching/2` and `:digraph_utils.reachable/2`.

### 4.5 Tests for Phase 4

#### Independence tests
```
test "x = 1; y = 2 → independent"
test "x = 1; y = x + 1 → dependent"
test "a |> b; a |> c where b and c are pure → independent"
test "a |> b; a |> c where b writes ETS → dependent on c if c reads ETS"
test "IO.puts(x); IO.puts(y) → dependent (IO ordering)"
test "Enum.map(x, &f/1); Enum.map(y, &g/1) → independent if x ≠ y and pure"
test "send(pid, msg1); send(pid, msg2) → dependent (message ordering)"
```

#### Slice tests
```
test "backward slice of return includes all contributing expressions"
test "forward slice of parameter reaches all uses"
test "independent expressions are not in each other's slices"
test "dead code is not in any backward slice from return"
```

---

## Phase 5 — Interprocedural (SDG)

**Goal:** Cross-function analysis via System Dependence Graph.

### 5.1 Call Graph

Build from IR:
- static calls: `Module.function(args)` → direct edge
- local calls: `function(args)` → direct edge
- dynamic calls: `apply(m, f, a)` → conservative edge to all matching arities
- higher-order: `Enum.map(list, &foo/1)` → edge to `foo/1`
- spawn: `spawn(fn -> ... end)` → edge to anonymous function

Use `:xref` in `functions` mode as a starting point for module-level call graph,
then refine with IR-level analysis.

### 5.2 SDG Construction

For each call site:
1. Create `actual-in` nodes for each argument
2. Create `actual-out` node for return value
3. Connect to `formal-in` / `formal-out` nodes in callee's PDG
4. Add call edge from call site to callee ENTRY
5. Compute **summary edges**: if formal-in `p` reaches formal-out `r` in callee's PDG, add summary edge from corresponding actual-in to actual-out

Summary edges enable context-sensitive slicing without re-entering the callee.

### 5.3 Context-Sensitive Slicing

Horwitz-Reps-Binkley two-phase algorithm:
1. Phase 1: slice backward in calling context (follow call edges down, don't follow return edges up)
2. Phase 2: from Phase 1 results, slice backward in called context (follow return edges up, don't follow call edges down)

This avoids "impossible paths" through call sites.

### 5.4 Tests for Phase 5

```
test "call to pure function creates data edges only through params/return"
test "call to impure function creates effect dependency"
test "recursive call doesn't create infinite graph"
test "higher-order call to known function resolves edges"
test "apply with variable module creates conservative edges"
test "context-sensitive slice doesn't include unreachable call paths"
test "summary edges shortcut intraprocedural analysis"
```

### Stealable references
- **Horwitz, Reps, Binkley 1990**: the SDG/context-sensitive slicing paper
- **Silva, Tamarit, Tomás 2012**: SDG adapted to Erlang (the FASE 2012 paper)
- **e-Knife call/input/output/summary edges**: Erlang-specific SDG edge types

---

## Phase 6 — Concurrency + Effects (Advanced)

**Goal:** Handle BEAM-specific concurrency patterns.

### 6.1 Message Dependence

- `send(pid, msg)` → `:send` effect
- `receive` → `:receive` effect
- If a send may reach a receive (same process or known pid), add message-dependence edge

Conservative: if we can't prove processes are different, assume dependence.

### 6.2 ETS / Process Dictionary

- `:ets.insert` → write effect on table
- `:ets.lookup` → read effect on table
- `Process.put` → write effect on process dict
- `Process.get` → read effect on process dict

Track which table/key if statically determinable.

### 6.3 GenServer State

- `handle_call` / `handle_cast` → read+write state
- State flows through `{:reply, result, new_state}` return tuples

Model as field-sensitive dependence on the state term.

### 6.4 Tests
```
test "two sends to same pid are ordered"
test "send to different pids with no shared state are independent"
test "ETS read after write to same table are dependent"
test "ETS operations on different tables are independent"
test "GenServer state flows through handle_call return"
```

---

## Phase 7 — Integration + Tooling

### 7.1 Mix Task

```
mix ex_pdg --file lib/my_module.ex --function my_fun/2 --format dot
mix ex_pdg.slice --file lib/my_module.ex --line 42 --direction backward
mix ex_pdg.independent --file lib/my_module.ex --line 10 --line 15
```

### 7.2 Programmatic API

```elixir
{:ok, pdg} = ExPDG.build_file("lib/my_module.ex")
{:ok, fn_pdg} = ExPDG.function_pdg(pdg, {MyModule, :my_fun, 2})

ExPDG.independent?(fn_pdg, node_a, node_b)
ExPDG.backward_slice(fn_pdg, node)
ExPDG.forward_slice(fn_pdg, node)
ExPDG.control_deps(fn_pdg, node)
ExPDG.data_deps(fn_pdg, node)
```

### 7.3 Visualization

- DOT export via `:digraph` → Graphviz
- JSON export for web viewers
- Mermaid export for documentation

### 7.4 ExDNA Integration

ExPDG provides the independence oracle that ExDNA can use to detect
reordering-equivalent clones:

```elixir
# In ex_dna clone comparison:
if ExPDG.same_pdg_structure?(pdg_a, pdg_b) do
  :clone  # even if statement order differs
end
```

---

## Donor Repositories + What to Take

| Source | License | What to take |
|--------|---------|-------------|
| **mchalupa/dg** | MIT | DDG/CDG layering, slicer architecture, test structure |
| **ARISTODE/program-dependence-graph** | MIT | PDG/CDG/DDG pass decomposition, graph reachability API |
| **grammarware/pdg** | — (academic) | Module boundaries (CFG→PDT→CDG→DDG→PDG→SDG), unit test shapes |
| **Joern/codepropertygraph** | Apache-2.0 | Node/edge schema design, query patterns, serialization |
| **angr CDG** | BSD-2 | Compact CDG construction via postdom + dominance frontier |
| **LLVM PostDominators** | Apache-2.0 | Lengauer-Tarjan reference, correctness expectations |
| **e-Knife** | — (academic/UPV) | Expression-level dependence for Erlang, edge taxonomy, benchmarks |
| **Silva et al. FASE 2012** | Paper | SDG adaptation for Erlang: pattern matching, HOF, recursion |
| **Tóth & Bozó 2011** | Paper | Dependency graph for Erlang slicing, RefactorErl integration |
| **Ferrante et al. 1987** | Paper | The CDG algorithm |
| **Horwitz, Reps, Binkley 1990** | Paper | SDG + context-sensitive slicing |
| **RefactorErl** | LGPL-3 | Reality check for industrial Erlang parsing edge cases |

**Rule:** Reimplement algorithms from papers and docs. Don't copy code from repos
without checking license compatibility. Test shapes and small example programs
are generally safe to independently recreate.

---

## Test Corpus Plan

### Unit tests per module
Every module (CFG, Dominator, CDG, DDG, PDG, SDG, Slicer) gets:
- hand-built micro-programs (5–15 lines)
- expected graph structure assertions
- edge-case tests for BEAM-specific constructs

### Golden tests
Directory of `.ex` files with expected slice outputs:
```
test/fixtures/
  straight_line.ex          → straight_line_backward_slice.expected
  if_else.ex                → if_else_cdg.expected
  case_clauses.ex           → case_clauses_cfg.expected
  pattern_match.ex          → pattern_match_ddg.expected
  pipe_chain.ex             → pipe_independence.expected
  try_catch.ex              → try_catch_cfg.expected
  receive_timeout.ex        → receive_cdg.expected
  multi_clause_function.ex  → multi_clause_cfg.expected
  genserver_state.ex        → genserver_ddg.expected
  ets_operations.ex         → ets_effects.expected
  higher_order.ex           → higher_order_sdg.expected
```

### Benchmarks
Adapted from:
- e-Knife Bencher examples (bench2–bench18.erl)
- Real-world Elixir modules from open-source projects
- OTP standard library modules as stress tests

### Property-based tests
Using StreamData:
- "CFG has exactly one ENTRY and at least one EXIT"
- "every non-ENTRY node is reachable from ENTRY"
- "post-dominator tree is a tree"
- "every node is post-dominated by EXIT"
- "CDG + DDG edges connect nodes within the same function"
- "backward slice from EXIT includes all non-dead nodes"
- "independent nodes have no path between them in DDG"

---

## Milestones + Estimated Effort

| Phase | Scope | Effort | Depends on |
|-------|-------|--------|------------|
| 0 | Project setup, IR design, decisions | 1 week | — |
| 1 | Frontend + CFG | 3–4 weeks | Phase 0 |
| 2 | Dominators + CDG | 2 weeks | Phase 1 |
| 3 | Reaching defs + DDG | 2–3 weeks | Phase 1 |
| 4 | PDG assembly + queries + effects | 2 weeks | Phase 2, 3 |
| 4b | Query macros (Ecto-style) + built-in rules | 3 weeks | Phase 4 |
| 5 | SDG (interprocedural) | 3–4 weeks | Phase 4 |
| 5b | OTP semantic model (GenServer, Supervisor, ETS, PubSub) | 3 weeks | Phase 5 |
| 6 | Concurrency + message-passing analysis | 3 weeks | Phase 5b |
| 7 | Tooling, Credo integration, visualization | 2 weeks | Phase 4b+ |

**MVP (Phases 0–4):** ~10 weeks for intraprocedural PDG with Elixir API.

**Usable linter (through Phase 4b):** ~13 weeks. This is when people can write rules.

**Full SDG (through Phase 5):** ~17 weeks.

**OTP-aware (through Phase 5b):** ~20 weeks. Understands GenServer state, message flow.

**Production-grade (all phases):** ~23 weeks.

See **QUERY_LANGUAGE.md** for the query macro design.
See **OTP_MODEL.md** for the OTP semantic model design.

---

## Open Questions

1. **Granularity:** Basic blocks vs individual expressions? Start with expressions (finer), coarsen later if too expensive.

2. **Elixir macros:** Analyze pre- or post-expansion? Post-expansion is easier but loses source mapping. Consider both: analyze expanded, map back to source.

3. **Typespec integration:** Can `@spec` annotations help with effect inference? Yes — a `@spec` with no side-effect types could whitelist purity.

4. **Incremental analysis:** Can we update the PDG when one function changes without rebuilding everything? Yes, if SDG summaries are cached per function.

5. **LiveView / Phoenix specifics:** Are there domain-specific dependence patterns worth modeling? Possibly — assign chains, socket state flow. Future work.

6. **Integration with Dialyzer:** Can we reuse Dialyzer's type/success typing information for better effect inference? Worth investigating.
