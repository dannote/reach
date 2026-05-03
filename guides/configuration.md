# Configuration

Reach reads architecture, change-safety, advisory candidate, and smell policy from `.reach.exs`.

```bash
mix reach.check --arch
mix reach.check --changed
mix reach.check --candidates
mix reach.check --smells
mix reach.inspect TARGET --candidates
```

The file must evaluate to a keyword list. Start from [`examples/reach.exs`](../examples/reach.exs), then tune it to your project.

```elixir
[
  layers: [
    web: "MyAppWeb.*",
    domain: "MyApp.*",
    data: ["MyApp.Repo", "MyApp.Schemas.*"]
  ],
  deps: [
    forbidden: [
      {:domain, :web},
      {:data, :web}
    ]
  ],
  source: [
    forbidden_modules: ["MyApp.Legacy.*"],
    forbidden_files: ["lib/my_app/legacy/**"]
  ],
  calls: [
    forbidden: [
      {"MyApp.Domain.*", ["IO.puts", "Jason.encode!"]},
      {"MyApp.Workers.*", ["System.cmd"], except: ["MyApp.Workers.Cleanup"]}
    ]
  ],
  effects: [
    allowed: [
      {"MyApp.Pure.*", [:pure, :unknown]}
    ]
  ],
  boundaries: [
    public: ["MyApp.Accounts"],
    internal: ["MyApp.Accounts.Internal.*"],
    internal_callers: [
      {"MyApp.Accounts.Internal.*", ["MyApp.Accounts", "MyApp.Accounts.*"]}
    ]
  ],
  risk: [
    changed: [
      many_direct_callers: 5,
      wide_transitive_callers: 10,
      branch_heavy: 8,
      high_risk_reason_count: 3
    ]
  ],
  candidates: [
    thresholds: [
      mixed_effect_count: 2,
      branchy_function_branches: 8,
      high_risk_direct_callers: 4
    ],
    limits: [
      per_kind: 20,
      representative_calls: 10,
      representative_calls_per_edge: 3
    ]
  ],
  smells: [
    fixed_shape_map: [
      min_keys: 3,
      min_occurrences: 3,
      evidence_limit: 10
    ]
  ],
  tests: [
    hints: [
      {"lib/my_app/accounts/**", ["test/my_app/accounts_test.exs"]}
    ]
  ]
]
```

The `deps`, `source`, `calls`, `effects`, `boundaries`, `risk`, `candidates`, `smells`, and `tests` sections use a uniform grouped shape: the section names the concern, and nested entries name the policy direction or threshold being tuned.

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

### `source[:forbidden_modules]`

Declare module names or namespaces that must not appear in the analyzed source tree. This is useful for making removed architecture impossible to reintroduce.

```elixir
source: [
  forbidden_modules: [
    "MyApp.Legacy.*",
    "MyApp.OldTaskRunner"
  ]
]
```

`mix reach.check --arch` reports `forbidden_module` violations with module, file, and line evidence.

### `source[:forbidden_files]`

Declare source paths that must not appear in the analyzed source tree.

```elixir
source: [
  forbidden_files: [
    "lib/my_app/legacy/**",
    "lib/my_app/old_task_runner.ex"
  ]
]
```

Path globs use the same `*` / `**` matching rules as module patterns. `mix reach.check --arch` reports `forbidden_file` violations.

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

### `risk[:changed]`

Tune changed-code risk thresholds used by `mix reach.check --changed`.

```elixir
risk: [
  changed: [
    many_direct_callers: 5,
    wide_transitive_callers: 10,
    branch_heavy: 8,
    high_risk_reason_count: 3
  ]
]
```

These thresholds control when a changed function is marked with risk reasons such as `many direct callers`, `wide transitive impact`, and `branch-heavy function`.

### `candidates[:thresholds]` and `candidates[:limits]`

Tune advisory refactoring candidate generation used by `mix reach.check --candidates` and `mix reach.inspect TARGET --candidates`.

```elixir
candidates: [
  thresholds: [
    mixed_effect_count: 2,
    branchy_function_branches: 8,
    high_risk_direct_callers: 4
  ],
  limits: [
    per_kind: 20,
    representative_calls: 10,
    representative_calls_per_edge: 3
  ]
]
```

Thresholds decide when Reach reports mixed-effect and branch-heavy extraction candidates. Limits bound candidate evidence and per-kind generation while preserving exact cycle-component detection.

### `smells[:fixed_shape_map]`

Tune repeated fixed-shape map smell detection.

```elixir
smells: [
  fixed_shape_map: [
    min_keys: 3,
    min_occurrences: 3,
    evidence_limit: 10
  ]
]
```

Use this when a codebase intentionally uses small map contracts, or when you want stronger pressure toward structs/contracts.

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
| `source[:forbidden_modules]` | `forbidden_modules` |
| `source[:forbidden_files]` | `forbidden_files` |

## Validation

Reach validates `.reach.exs` shape and reports `config_error` entries for:

- unknown top-level or grouped keys
- invalid `layers`
- invalid `deps[:forbidden]`
- invalid `source[:forbidden_modules]`
- invalid `source[:forbidden_files]`
- invalid `calls[:forbidden]`
- invalid `effects[:allowed]`
- invalid `boundaries[:public]`
- invalid `boundaries[:internal]`
- invalid `boundaries[:internal_callers]`
- invalid `risk[:changed]` thresholds
- invalid `candidates[:thresholds]`
- invalid `candidates[:limits]`
- invalid `smells[:fixed_shape_map]`
- invalid `tests[:hints]`

## Practical guidance

Start permissive and tighten gradually:

1. Define broad layers.
2. Add only the forbidden dependencies you are confident about.
3. Add boundary policies for namespaces with clear public/internal modules.
4. Add effect policies for modules that should stay pure or effect-limited.
5. Tune `risk[:changed]`, `candidates`, and `smells` thresholds to match your repository size and tolerance for advisory output.
6. Run `mix reach.check --arch --format json` in CI once the policy is stable.

Refactoring candidates are advisory. They include `confidence`, `actionability`, and `proof` fields. Treat those fields as preconditions for editing, especially for cycle and extraction candidates.
