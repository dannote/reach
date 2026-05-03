# Configuration

Reach reads `.reach.exs` for architecture and change-safety policy.

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
  tests: [
    hints: [
      {"lib/my_app/accounts/**", ["test/my_app/accounts_test.exs"]}
    ]
  ]
]
```

The `deps`, `source`, `calls`, `effects`, `boundaries`, and `tests` sections use a uniform grouped shape: the section names the concern, and nested `forbidden`, `forbidden_modules`, `allowed`, or `hints` entries name the policy direction.

Run:

```bash
mix reach.check --arch
mix reach.check --changed --base main
```

See `CONFIG.md` for the complete key reference and compatibility aliases for older flat keys.
