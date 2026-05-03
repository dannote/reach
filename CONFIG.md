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

### `deps[:forbidden]`

Declare layer-to-layer dependencies that should not exist.

```elixir
deps: [
  forbidden: [
    {:domain, :web},
    {:data, :web}
  ]
]
```

`mix reach.check --arch` reports `forbidden_dependency` violations with caller, callee, call, file, and line evidence.

### `calls[:forbidden]`

Declare calls that matching modules must not make. This is useful for enforcing presentation/IO boundaries or other call-level rules that are more precise than layer dependencies.

```elixir
calls: [
  forbidden: [
    {"MyApp.Domain.*", ["IO.puts", "Jason.encode!"]},
    {"MyApp.Workers.*", ["System.cmd", "File.rm"], except: ["MyApp.Workers.Cleanup"]}
  ]
]
```

Each entry is either:

```elixir
{caller_patterns, call_patterns}
{caller_patterns, call_patterns, except: except_caller_patterns}
```

Patterns use the same module/call glob syntax as layers. Call patterns may include or omit arity:

```elixir
"IO.puts"
"IO.puts/1"
"Reach.CLI.Format.render"
"Jason.encode!"
```

`mix reach.check --arch` reports `forbidden_call` violations with caller module, call, file, and line evidence.

### `effects[:allowed]`

Limit side-effect classes for matching modules.

```elixir
effects: [
  allowed: [
    {"MyApp.Pure.*", [:pure, :unknown]},
    {"MyAppWeb.*", [:pure, :read, :write, :send, :io, :unknown]}
  ]
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

### `boundaries[:public]`

Declare top-level public modules that callers should use as boundaries.

```elixir
boundaries: [
  public: [
    "MyApp.Accounts",
    "MyApp.Billing"
  ]
]
```

If a caller reaches into another module under the same namespace instead of going through the declared public API, `mix reach.check --arch` may report a `public_api_boundary` violation.

### `boundaries[:internal]`

Declare modules that should be treated as internal implementation details.

```elixir
boundaries: [
  internal: [
    "MyApp.Accounts.Internal.*",
    "MyApp.Billing.Calculators.*"
  ]
]
```

Calls into these modules from outside approved callers produce `internal_boundary` violations.

### `boundaries[:internal_callers]`

Allow specific callers to reach specific internal modules.

```elixir
boundaries: [
  internal_callers: [
    {"MyApp.Accounts.Internal.*", ["MyApp.Accounts", "MyApp.Accounts.*"]}
  ]
]
```

Use this to make policy precise instead of making internal modules public.

### `tests[:hints]`

Suggest tests for changed paths.

```elixir
tests: [
  hints: [
    {"lib/my_app/accounts/**", ["test/my_app/accounts_test.exs"]},
    {"lib/my_app_web/live/**", ["test/my_app_web/live"]}
  ]
]
```

`mix reach.check --changed` combines these hints with nearby test paths and caller impact data.

## Compatibility aliases

Reach accepts the previous flat keys as compatibility aliases, but new configs should use the grouped form.

| Preferred | Compatibility alias |
| --- | --- |
| `deps[:forbidden]` | `forbidden_deps` |
| `calls[:forbidden]` | `forbidden_calls` |
| `effects[:allowed]` | `allowed_effects` |
| `boundaries[:public]` | `public_api` |
| `boundaries[:internal]` | `internal` |
| `boundaries[:internal_callers]` | `internal_callers` |
| `tests[:hints]` | `test_hints` |

## Validation

Reach validates `.reach.exs` shape and reports `config_error` entries for:

- unknown top-level or grouped keys
- invalid `layers`
- invalid `deps[:forbidden]`
- invalid `calls[:forbidden]`
- invalid `effects[:allowed]`
- invalid `boundaries[:public]`
- invalid `boundaries[:internal]`
- invalid `boundaries[:internal_callers]`
- invalid `tests[:hints]`

## Practical guidance

Start permissive and tighten gradually:

1. Define broad layers.
2. Add only the forbidden dependencies you are confident about.
3. Add boundary policies for namespaces with clear public/internal modules.
4. Add effect policies for modules that should stay pure or effect-limited.
5. Run `mix reach.check --arch --format json` in CI once the policy is stable.

Refactoring candidates are advisory. They include `confidence`, `actionability`, and `proof` fields. Treat those fields as preconditions for editing, especially for cycle and extraction candidates.
