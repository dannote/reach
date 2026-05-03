# Configuration

Reach reads `.reach.exs` for architecture and change-safety policy.

```elixir
[
  layers: [
    web: "MyAppWeb.*",
    domain: "MyApp.*",
    data: ["MyApp.Repo", "MyApp.Schemas.*"]
  ],
  forbidden_deps: [
    {:domain, :web},
    {:data, :web}
  ],
  forbidden_calls: [
    {"MyApp.Domain.*", ["IO.puts", "Jason.encode!"]},
    {"MyApp.Workers.*", ["System.cmd"], except: ["MyApp.Workers.Cleanup"]}
  ],
  allowed_effects: [
    {"MyApp.Pure.*", [:pure, :unknown]}
  ],
  public_api: ["MyApp.Accounts"],
  internal: ["MyApp.Accounts.Internal.*"],
  internal_callers: [
    {"MyApp.Accounts.Internal.*", ["MyApp.Accounts", "MyApp.Accounts.*"]}
  ],
  test_hints: [
    {"lib/my_app/accounts/**", ["test/my_app/accounts_test.exs"]}
  ]
]
```

Run:

```bash
mix reach.check --arch
mix reach.check --changed --base main
```

See `CONFIG.md` for the complete key reference.
