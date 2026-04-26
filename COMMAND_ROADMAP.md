# Reach Command Roadmap

This roadmap keeps the Mix task surface dotted and consolidates existing tools into a smaller set of user-facing concepts. Existing commands remain as compatibility aliases, but docs should guide users toward the canonical dotted commands below.

## Goals

- Reduce command-choice confusion.
- Avoid overlap with Credo, ExDna, coverage tools, and generic linting.
- Keep Reach focused on structural program understanding: dependencies, data/control flow, effects, OTP, impact, and architecture boundaries.
- Provide agent-friendly context without creating many agent-specific commands.
- Make architecture policy checks a first-class feature.

## Canonical Commands

### `mix reach`

Generate the interactive HTML report.

Current purpose stays intact:

- Control Flow view
- Call Graph view
- Data Flow view

Example:

```bash
mix reach
mix reach lib/my_app/accounts.ex
mix reach --output report.html
```

### `mix reach.map`

Project bird's-eye view.

Absorbs the project-wide overview commands:

- `reach.modules`
- `reach.coupling`
- `reach.hotspots`
- `reach.depth`
- `reach.effects`
- `reach.boundaries`
- global parts of `reach.xref`

Examples:

```bash
mix reach.map
mix reach.map --modules
mix reach.map --coupling
mix reach.map --hotspots
mix reach.map --effects
mix reach.map --boundaries
mix reach.map --depth
mix reach.map --data
mix reach.map --format json
```

Default output should be curated rather than exhaustive:

- module/layer overview
- top hotspots
- top coupling/cycles
- top mixed-effect functions
- notable data-flow risks when `--data` is passed
- architecture notes when `.reach.exs` exists

### `mix reach.inspect TARGET`

Explain one function, module, file, or line.

Absorbs target-oriented commands:

- `reach.deps`
- `reach.impact`
- `reach.slice`
- `reach.graph`
- target-specific parts of `reach.xref`

Examples:

```bash
mix reach.inspect Reach.Frontend.Elixir.translate/3
mix reach.inspect lib/reach/frontend/elixir.ex:54
mix reach.inspect Reach.Visualize.ControlFlow
mix reach.inspect TARGET --deps
mix reach.inspect TARGET --impact
mix reach.inspect TARGET --slice
mix reach.inspect TARGET --graph
mix reach.inspect TARGET --data
mix reach.inspect TARGET --context
mix reach.inspect TARGET --candidates
mix reach.inspect TARGET --format markdown
mix reach.inspect TARGET --format json
```

Important modes:

- `--context` emits an agent-readable context pack.
- `--impact` shows blast radius.
- `--data` shows target-local data definitions, uses, returns, and external flows.
- `--candidates` shows graph-backed refactoring candidates for the target.

### `mix reach.trace`

Data-flow, taint, and slicing queries.

Absorbs:

- `reach.flow`
- data-flow-oriented use cases from `reach.slice`

Examples:

```bash
mix reach.trace --from conn.params --to Repo
mix reach.trace --from conn.params --to System.cmd
mix reach.trace --variable user --in MyApp.Accounts.create/1
mix reach.trace --backward lib/my_app/accounts.ex:45
mix reach.trace --forward lib/my_app/accounts.ex:45
mix reach.trace --format json
```

Use this for questions like:

- Where does this value come from?
- Where can this value go?
- Can this source reach this sink?
- Is this path sanitized?

### `mix reach.otp`

OTP, process, message, state, and supervision analysis.

Absorbs:

- `reach.otp`
- `reach.concurrency`

Examples:

```bash
mix reach.otp
mix reach.otp MyApp.Worker
mix reach.otp --concurrency
mix reach.otp --state
mix reach.otp --messages
mix reach.otp --supervision
mix reach.otp --format json
```

OTP remains separate because it has a distinct mental model from ordinary call/data-flow analysis.

### `mix reach.check`

Structural validation and change safety.

Absorbs:

- `reach.dead_code`
- `reach.smell`
- new architecture checks
- changed-code impact checks
- project-wide refactoring candidate checks

Examples:

```bash
mix reach.check
mix reach.check --arch
mix reach.check --changed
mix reach.check --changed --base main
mix reach.check --dead-code
mix reach.check --smells
mix reach.check --candidates
mix reach.check --format json
```

Important modes:

- `--arch` checks `.reach.exs` architecture policy.
- `--changed --base main` reports changed functions, impact, effect changes, architecture violations, and suggested tests.
- `--dead-code` should stay narrowly defined as unused pure expressions, not generic dead-code detection.
- `--smells` should stay graph/effect/data-flow based, not generic style linting.
- `--candidates` emits project-wide graph-backed refactoring candidates.

## Compatibility Aliases

Keep old tasks as wrappers. They should continue working, but the docs should prefer the canonical dotted commands.

| Existing command | Canonical equivalent |
|---|---|
| `mix reach.modules` | `mix reach.map --modules` |
| `mix reach.coupling` | `mix reach.map --coupling` |
| `mix reach.hotspots` | `mix reach.map --hotspots` |
| `mix reach.depth` | `mix reach.map --depth` |
| `mix reach.effects` | `mix reach.map --effects` |
| `mix reach.boundaries` | `mix reach.map --boundaries` |
| `mix reach.deps TARGET` | `mix reach.inspect TARGET --deps` |
| `mix reach.impact TARGET` | `mix reach.inspect TARGET --impact` |
| `mix reach.slice TARGET` | `mix reach.inspect TARGET --slice` or `mix reach.trace --backward TARGET` |
| `mix reach.graph TARGET` | `mix reach.inspect TARGET --graph` |
| `mix reach.flow ...` | `mix reach.trace ...` |
| `mix reach.xref` | `mix reach.map --xref` or `mix reach.inspect TARGET --xref` |
| `mix reach.concurrency` | `mix reach.otp --concurrency` |
| `mix reach.dead_code` | `mix reach.check --dead-code` |
| `mix reach.smell` | `mix reach.check --smells` |

## Architecture Policy Checks

Add `.reach.exs` support and make architecture validation part of `mix reach.check --arch`.

Example shape:

```elixir
[
  layers: [
    cli: "Mix.Tasks.*",
    public_api: ["Reach", "Reach.Project"],
    frontend: "Reach.Frontend.*",
    ir: "Reach.IR.*",
    analysis: [
      "Reach.ControlFlow",
      "Reach.DataDependence",
      "Reach.ControlDependence",
      "Reach.Dominator",
      "Reach.SystemDependence",
      "Reach.Effects"
    ],
    visualization: "Reach.Visualize.*",
    plugins: "Reach.Plugins.*"
  ],

  forbidden_deps: [
    {:ir, :cli},
    {:analysis, :cli},
    {:frontend, :visualization},
    {:frontend, :cli},
    {:ir, :visualization}
  ],

  allowed_effects: [
    {"Reach.IR.*", [:pure]},
    {"Reach.ControlFlow", [:pure]},
    {"Reach.Dominator", [:pure]},
    {"Mix.Tasks.*", [:io, :read, :write]}
  ],

  test_hints: [
    {"lib/reach/visualize/**", [
      "test/visualize/block_quality_test.exs",
      "test/visualize_test.exs"
    ]},
    {"lib/reach/frontend/elixir.ex", [
      "test/ir/frontend_elixir_test.exs"
    ]}
  ]
]
```

Initial checks:

- forbidden module dependencies
- forbidden function calls across layers
- cycles between configured layers
- effect leakage into pure/core layers
- configured public API boundary violations

## Data-Flow Graph UX

Data-flow analysis remains first-class but does not get a separate command.

Use these entrypoints:

```bash
mix reach                         # HTML Data Flow tab
mix reach.map --data              # project-level data-flow summary
mix reach.inspect TARGET --data   # target-local data-flow view
mix reach.trace ...               # source/sink and slicing queries
```

This avoids the confusing split between `data`, `flow`, `slice`, and `trace` commands.

## Refactoring Support

Do not add a top-level `mix reach.refactor` command initially.

Reach should provide evidence and candidates:

```bash
mix reach.inspect TARGET --candidates
mix reach.check --candidates
```

A separate refactoring skill should make judgment calls, rank candidates, and enforce proof discipline.

Reach-native candidate types:

1. extract pure single-entry/single-exit region
2. isolate side effects from decision logic
3. break dependency cycle
4. move misplaced helper across architecture layers
5. introduce facade/boundary for policy violations
6. validate true duplication before collapse
7. shrink public API surface when safe

Avoid generic refactoring advice that overlaps with Credo or ExDna:

- function too long
- naming/style complaints
- generic nesting complaints
- pipe/style preferences
- abstraction for hypothetical future reuse

Rule of thumb:

> No graph/effect/flow/architecture evidence, no Reach refactoring candidate.

## Suggested Tests

Do not add `mix reach.tests`.

Suggested tests should appear inside:

```bash
mix reach.inspect TARGET --impact
mix reach.check --changed --base main
```

This differs from coverage. Coverage says what executed. Reach should suggest which tests are relevant to this change based on:

- path/name proximity
- call graph impact
- affected Mix tasks/public APIs
- architecture `test_hints`
- specialized invariants such as visualization block quality

## Implementation Phases

### Phase 1: Command wrappers and documentation

- Add canonical dotted tasks:
  - `Mix.Tasks.Reach.Map`
  - `Mix.Tasks.Reach.Inspect`
  - `Mix.Tasks.Reach.Trace`
  - `Mix.Tasks.Reach.Check`
- Keep `Mix.Tasks.Reach.Otp` as the canonical OTP command.
- Convert old commands into wrappers or update them to delegate internally.
- Update README command docs to teach the six-command model.

### Phase 2: Shared output schemas

- Standardize JSON envelopes for canonical commands.
- Keep old JSON keys compatible where practical.
- Add schema docs for agent/tool consumers.

### Phase 3: Context and changed-code impact

- Implement `reach.inspect --context`.
- Implement `reach.check --changed --base <ref>`.
- Include suggested tests in changed-code impact output.

### Phase 4: Architecture policy

- Add `.reach.exs` parser.
- Implement layer matching.
- Implement forbidden dependency and layer-cycle checks.
- Add effect policy checks.

### Phase 5: Refactoring candidates

- Implement candidate emission for:
  - dependency cycles
  - misplaced layer helpers
  - mixed-effect functions
  - pure extractable regions
- Keep output advisory and evidence-based.
- Do not perform edits.

### Phase 6: Agent/server integration

- Keep CLI as source of truth.
- Optionally expose the canonical operations through MCP or JSON-RPC later:
  - map
  - inspect
  - trace
  - otp
  - check

## Documentation Model

Docs should teach Reach as six actions:

```text
1. reach          generate interactive graph report
2. reach.map      understand project structure
3. reach.inspect  understand one target
4. reach.trace    follow data/value flow
5. reach.otp      analyze OTP/process behavior
6. reach.check    validate architecture and change safety
```

Then provide task-oriented examples:

```bash
# I just opened a project
mix reach.map

# I am editing a function
mix reach.inspect MyApp.Accounts.create_user/1 --context

# I changed code and want risk/test guidance
mix reach.check --changed --base main

# I need to check a security path
mix reach.trace --from conn.params --to System.cmd

# I need OTP insight
mix reach.otp --messages
```
