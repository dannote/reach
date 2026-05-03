# ExDoc Restructure Plan

## What mature Elixir projects do

Reviewed ExDoc setups from Phoenix, Ecto, Oban, Livebook, Phoenix LiveView, Req, Nx, Tesla, Ash, and LiveDashboard. Common patterns:

1. **Use README as the public landing page** for small libraries, but switch `main` to a curated guide when docs grow into a product surface.
   - Phoenix uses `main: "overview"` with a large Introduction guide set.
   - Ecto and Oban use their primary module as the API landing page while guides are grouped separately.
   - Livebook uses `README.md` as a branded welcome page and hides broad API reference via `api_reference: false` for an app-style project.

2. **Move long-form documentation into `guides/`** and keep README short.
   - Phoenix, Ecto, Oban, LiveView, and Nx all organize extras by guide folders, then use `groups_for_extras` for navigation.
   - Changelog remains an extra, often with `skip_undefined_reference_warnings_on: ["CHANGELOG.md"]`.

3. **Group extras by user journey, not implementation namespace.**
   - Typical groups: Introduction, Getting Started, Core Concepts, How-to/Recipes, Testing, Deployment/Operations, Upgrading.
   - Oban's split is especially relevant for Reach: Introduction, Learning, Advanced, Recipes, Testing, Upgrading.

4. **Group modules around the public API.**
   - Libraries with many modules use `groups_for_modules` to separate main API, plugins/adapters, internals/support, and testing helpers.
   - Projects with nested namespaces often add `nest_modules_by_prefix` for readability.

5. **Use `groups_for_docs` when function docs are intentionally tagged.**
   - Phoenix/LiveView group callbacks/macros/components.
   - Req groups request/response/error steps.
   - Nx groups functions by tags such as creation, aggregation, conversion.
   - Reach can later tag CLI, analysis, graph, and visualization public functions if API docs get too flat.

6. **Expose assets only when they improve comprehension.**
   - Phoenix and Livebook include guide images/assets and custom JS for diagrams.
   - Reach already has visual outputs; screenshots or generated graph examples would be helpful in guides.

7. **Keep source links release-stable.**
   - Popular projects use `source_ref: "v#{@version}"`; Reach already does this.

## Current Reach docs shape

Current ExDoc config is minimal:

```elixir
main: "Reach",
extras: ["README.md", "CHANGELOG.md", "CONFIG.md", "LICENSE"],
groups_for_modules: [
  "Public API": [Reach, Reach.Project],
  IR: [Reach.IR, Reach.IR.Node],
  Analysis: [Reach.Effects],
  Frontends: [Reach.Frontend.Elixir, Reach.Frontend.Erlang]
]
```

This is now too small for the 2.0 CLI/product surface. README carries too many jobs:

- product overview
- installation
- command reference
- JSON contract hints
- architecture config
- examples
- validation story

## Proposed documentation structure

Create a `guides/` tree and keep README as a concise landing page.

```text
guides/
  introduction/
    overview.md
    installation.md
    quickstart.md
  cli/
    map.md
    inspect.md
    trace.md
    check.md
    otp.md
    json-output.md
    removed-commands.md
  configuration/
    architecture-policy.md
    forbidden-calls.md
    changed-code.md
  concepts/
    program-dependence-graph.md
    control-flow.md
    call-graph.md
    data-flow.md
    effects.md
    otp-analysis.md
  validation/
    real-codebases.md
    program-facts.md
    block-quality.md
  recipes/
    review-a-change.md
    find-refactoring-candidates.md
    trace-tainted-input.md
    inspect-otp-coupling.md
  contributing/
    cli-architecture.md
    release-checklist.md
```

## Proposed `mix.exs` docs config

```elixir
defp docs do
  [
    main: "overview",
    source_url: @source_url,
    source_ref: "v#{@version}",
    extra_section: "GUIDES",
    extras: extras(),
    groups_for_extras: groups_for_extras(),
    groups_for_modules: groups_for_modules(),
    skip_undefined_reference_warnings_on: ["CHANGELOG.md"]
  ]
end

defp extras do
  [
    "guides/introduction/overview.md",
    "guides/introduction/installation.md",
    "guides/introduction/quickstart.md",
    "guides/cli/map.md",
    "guides/cli/inspect.md",
    "guides/cli/trace.md",
    "guides/cli/check.md",
    "guides/cli/otp.md",
    "guides/cli/json-output.md",
    "guides/cli/removed-commands.md",
    "guides/configuration/architecture-policy.md",
    "guides/configuration/forbidden-calls.md",
    "guides/configuration/changed-code.md",
    "guides/concepts/program-dependence-graph.md",
    "guides/concepts/control-flow.md",
    "guides/concepts/call-graph.md",
    "guides/concepts/data-flow.md",
    "guides/concepts/effects.md",
    "guides/concepts/otp-analysis.md",
    "guides/validation/real-codebases.md",
    "guides/validation/program-facts.md",
    "guides/validation/block-quality.md",
    "guides/recipes/review-a-change.md",
    "guides/recipes/find-refactoring-candidates.md",
    "guides/recipes/trace-tainted-input.md",
    "guides/recipes/inspect-otp-coupling.md",
    "guides/contributing/cli-architecture.md",
    "guides/contributing/release-checklist.md",
    "CHANGELOG.md": [title: "Changelog"],
    "LICENSE": [title: "License"]
  ]
end

defp groups_for_extras do
  [
    Introduction: ~r{guides/introduction/[^/]+\.md},
    "Canonical CLI": ~r{guides/cli/[^/]+\.md},
    Configuration: ~r{guides/configuration/[^/]+\.md},
    Concepts: ~r{guides/concepts/[^/]+\.md},
    Validation: ~r{guides/validation/[^/]+\.md},
    Recipes: ~r{guides/recipes/[^/]+\.md},
    Contributing: ~r{guides/contributing/[^/]+\.md}
  ]
end

defp groups_for_modules do
  [
    "Public API": [Reach, Reach.Project],
    "CLI Commands": [~r/Reach\.CLI\.Commands/],
    "CLI Rendering": [~r/Reach\.CLI\.Render/],
    "Project Queries": [Reach.Project.Query],
    Inspect: [~r/Reach\.Inspect/],
    Map: [~r/Reach\.Map/],
    Trace: [~r/Reach\.Trace/],
    Check: [~r/Reach\.Check/],
    Smells: [~r/Reach\.Smell/],
    OTP: [~r/Reach\.OTP/],
    IR: [Reach.IR, Reach.IR.Node, Reach.IR.Helpers],
    Analysis: [Reach.ControlFlow, Reach.DataDependence, Reach.ControlDependence, Reach.Dominator, Reach.Effects, Reach.SystemDependence],
    Frontends: [~r/Reach\.Frontend/],
    Visualization: [~r/Reach\.Visualize/],
    Plugins: [Reach.Plugin, ~r/Reach\.Plugins/]
  ]
end
```

## Migration plan

1. **Add guide skeletons first** using existing README/CONFIG/VALIDATION content. Do not rewrite prose and code at the same time.
2. **Change ExDoc config** to `main: "overview"`, `extra_section: "GUIDES"`, grouped extras, and expanded module groups.
3. **Shrink README** to installation, 30-second quickstart, command table, and links to guides.
4. **Move detailed command docs** into one guide per canonical task.
5. **Move `.reach.exs` docs** from `CONFIG.md` into `guides/configuration/*`; keep `CONFIG.md` as a compatibility landing page or redirect-style summary.
6. **Move validation docs** (`VALIDATION_20_CODEBASES.md`, `VALIDATION_CANONICAL_FULL.md`, ProgramFacts notes) into `guides/validation/*`.
7. **Add generated-output screenshots/examples later** after the content hierarchy is stable.
8. **Run `mix docs --warnings-as-errors` equivalent gate** by keeping the existing `mix docs` clean and adding stricter link checks only if they stay low-noise.

## Acceptance criteria

- `mix docs` is warning-free.
- HexDocs landing page explains what Reach does within one screen.
- Each canonical command has a dedicated guide with text, JSON, and use-case examples.
- `.reach.exs` policies are documented with examples, including `forbidden_calls`.
- Module docs are navigable by subsystem, not a flat namespace dump.
- README is concise and points to HexDocs for details.
