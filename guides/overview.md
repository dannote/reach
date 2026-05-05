# Overview

Reach builds a program dependence graph for Elixir, Erlang, Gleam, JavaScript, and TypeScript projects and turns it into command-line reports and interactive HTML visualizations.

Use Reach when you want to answer questions such as:

- What are the riskiest functions to change?
- Which modules are tightly coupled?
- Where does a value, tainted input, or return shape flow?
- Which functions mix unrelated side effects?
- Which OTP processes hide state, message, or coupling risks?

Reach 2.x is organized around five canonical Mix tasks:

| Command | Purpose |
|---|---|
| `mix reach.map` | Project-level map: modules, coupling, hotspots, effects, depth, and data-flow summaries |
| `mix reach.inspect TARGET` | Target-local explanations: dependencies, impact, graph, context, data, candidates, and why paths |
| `mix reach.trace` | Data-flow, taint, and slicing workflows |
| `mix reach.check` | CI/release checks: architecture, changed-code risk, dead code, smells, and candidates |
| `mix reach.otp` | OTP/process analysis: behaviours, state machines, supervision, concurrency, and coupling |

For machine consumers, use `--format json`. Canonical commands emit pure JSON envelopes with stable command names.

## Design goals

Reach reports evidence. It does not auto-edit your code. Refactoring candidates are advisory and include graph/effect/architecture evidence so humans can decide what is safe.
