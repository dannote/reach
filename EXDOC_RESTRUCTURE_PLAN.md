# ExDoc Restructure Plan

## What mature Elixir projects do

Reviewed ExDoc setups from Phoenix, Ecto, Oban, Livebook, Phoenix LiveView, Req, Nx, Tesla, Ash, and LiveDashboard. Common patterns:

1. **Use README as the public landing page for small libraries, but switch `main` to a curated guide when docs grow into a product surface.** Phoenix uses `main: "overview"`; Ecto and Oban use a primary API module; Livebook uses a branded README and hides broad API reference.
2. **Move long-form documentation into `guides/` and keep README short.** Phoenix, Ecto, Oban, LiveView, and Nx all use grouped extras for guide navigation.
3. **Group extras by user journey, not implementation namespace.** Typical groups are Introduction, CLI/Usage, Configuration, Concepts, Validation, Recipes, and Contributing.
4. **Group modules around the public API.** Mature projects use `groups_for_modules` to separate public API, adapters/plugins, internals, and support namespaces.
5. **Use `groups_for_docs` only when function docs are intentionally tagged.** Reach can defer this until public functions have meaningful metadata tags.
6. **Keep source links release-stable.** Popular projects use `source_ref: "v#{@version}"`; Reach already does this.

## Reach 2.0 documentation shape

The first restructuring pass intentionally keeps guides flat rather than creating deep folders. That gives HexDocs a clear guide hierarchy without making the source tree noisy.

```text
guides/
  overview.md
  installation.md
  quickstart.md
  cli.md
  json-output.md
  configuration.md
  concepts.md
  validation.md
  recipes.md
  contributing.md
```

This collapses the earlier nested proposal into a smaller set of journey-oriented pages:

- `overview.md` — product landing page
- `installation.md` and `quickstart.md` — first-run path
- `cli.md` and `json-output.md` — canonical command surface
- `configuration.md` — `.reach.exs` overview, with `CONFIG.md` retained as the detailed reference
- `concepts.md` — PDG, CFG, call graph, data flow, effects, OTP concepts
- `validation.md` — CI, canonical validation, ProgramFacts, block quality
- `recipes.md` — task-oriented workflows
- `contributing.md` — CLI architecture and release checklist

## Implemented ExDoc config

Reach now uses a guide as the landing page:

```elixir
main: "overview",
extra_section: "GUIDES",
extras: extras(),
groups_for_extras: groups_for_extras(),
groups_for_modules: groups_for_modules(),
source_ref: "v#{@version}"
```

Guide groups are intentionally shallow:

```elixir
Introduction: ["guides/overview.md", "guides/installation.md", "guides/quickstart.md"],
"Canonical CLI": ["guides/cli.md", "guides/json-output.md"],
Configuration: ["guides/configuration.md", "CONFIG.md"],
Concepts: ["guides/concepts.md"],
Validation: ["guides/validation.md"],
Recipes: ["guides/recipes.md"],
Contributing: ["guides/contributing.md"]
```

Module groups now reflect the architecture:

- Public API
- CLI Commands
- CLI Rendering
- Project Queries
- Inspect
- Map
- Trace
- Check
- Smells
- OTP
- IR
- Analysis
- Frontends
- Visualization
- Plugins

## Remaining documentation work

1. Shrink `README.md` to a concise landing page with links to HexDocs guides.
2. Expand `guides/cli.md` with one complete example per canonical command.
3. Move detailed `.reach.exs` prose from `CONFIG.md` into `guides/configuration.md`, then keep `CONFIG.md` as a key reference.
4. Move validation details from `VALIDATION_20_CODEBASES.md` and `VALIDATION_CANONICAL_FULL.md` into `guides/validation.md` or remove the standalone files if duplicated.
5. Add screenshots or generated report snippets after the guide structure stabilizes.
6. Consider `groups_for_docs` later if public function docs gain tags such as CLI, analysis, graph, visualization, or policy.

## Acceptance criteria

- `mix docs` is warning-free.
- HexDocs opens on the overview guide.
- Canonical commands are documented from one guide page.
- `.reach.exs` policies are documented, including `forbidden_calls`.
- Module docs are navigable by subsystem, not a flat namespace dump.
- README is concise and points to HexDocs for details.
