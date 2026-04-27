# Reach Configuration

Reach reads architecture and change-safety policy from `.reach.exs` when running:

```bash
mix reach.check --arch
mix reach.check --changed
mix reach.check --candidates
```

The file must evaluate to a keyword list. Start from [`examples/reach.exs`](examples/reach.exs), then tune it to your project.

## Keys

### `layers`

Assign modules to architectural layers.

```elixir
layers: [
  web: "MyAppWeb.*",
  domain: ["MyApp.Accounts", "MyApp.Billing", "MyApp.Catalog"],
  data: "MyApp.Repo"
]
```

Patterns are module-name strings with `*` wildcards. A layer may have one pattern or a list of patterns.

### `forbidden_deps`

Declare layer-to-layer dependencies that should not exist.

```elixir
forbidden_deps: [
  {:domain, :web},
  {:data, :web}
]
```

`mix reach.check --arch` reports `forbidden_dependency` violations with caller, callee, call, file, and line evidence.

### `allowed_effects`

Limit side-effect classes for matching modules.

```elixir
allowed_effects: [
  {"MyApp.Pure.*", [:pure, :unknown]},
  {"MyAppWeb.*", [:pure, :read, :write, :send, :io, :unknown]}
]
```

Known effect atoms include:

- `:pure`
- `:io`
- `:read`
- `:write`
- `:send`
- `:receive`
- `:exception`
- `:nif`
- `:unknown`

Use this for architectural boundaries, not style linting. For example, keeping parsers or pure domain modules free from writes is a good fit; replacing Credo rules is not.

### `public_api`

Declare top-level public modules that callers should use as boundaries.

```elixir
public_api: [
  "MyApp.Accounts",
  "MyApp.Billing"
]
```

If a caller reaches into another module under the same namespace instead of going through the declared public API, `mix reach.check --arch` may report a `public_api_boundary` violation.

### `internal`

Declare modules that should be treated as internal implementation details.

```elixir
internal: [
  "MyApp.Accounts.Internal.*",
  "MyApp.Billing.Calculators.*"
]
```

Calls into these modules from outside approved callers produce `internal_boundary` violations.

### `internal_callers`

Allow specific callers to reach specific internal modules.

```elixir
internal_callers: [
  {"MyApp.Accounts.Internal.*", ["MyApp.Accounts", "MyApp.Accounts.*"]}
]
```

Use this to make policy precise instead of making internal modules public.

### `test_hints`

Suggest tests for changed paths.

```elixir
test_hints: [
  {"lib/my_app/accounts/**", ["test/my_app/accounts_test.exs"]},
  {"lib/my_app_web/live/**", ["test/my_app_web/live"]}
]
```

`mix reach.check --changed` combines these hints with nearby test paths and caller impact data.

## Validation

Reach validates `.reach.exs` shape and reports `config_error` entries for:

- unknown keys
- invalid `layers`
- invalid `forbidden_deps`
- invalid `allowed_effects`
- invalid `public_api`
- invalid `internal`
- invalid `internal_callers`
- invalid `test_hints`

## Practical guidance

Start permissive and tighten gradually:

1. Define broad layers.
2. Add only the forbidden dependencies you are confident about.
3. Add `public_api` and `internal` policies for namespaces with clear boundaries.
4. Add `allowed_effects` for modules that should stay pure or effect-limited.
5. Run `mix reach.check --arch --format json` in CI once the policy is stable.

Refactoring candidates are advisory. They include `confidence`, `actionability`, and `proof` fields. Treat those fields as preconditions for editing, especially for cycle and extraction candidates.
