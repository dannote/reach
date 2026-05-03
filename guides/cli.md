# Canonical CLI

Reach 2.x keeps the command surface intentionally small. Older task names are removed and replaced by modes on the canonical commands.

## `mix reach.map`

Project-level inventory and risk map.

```bash
mix reach.map
mix reach.map PATH
mix reach.map --modules
mix reach.map --coupling --sort instability
mix reach.map --effects
mix reach.map --boundaries --min 3
mix reach.map --depth --top 20
mix reach.map --data
```

## `mix reach.inspect TARGET`

Target-local investigation.

```bash
mix reach.inspect Module.function/arity --deps
mix reach.inspect Module.function/arity --impact
mix reach.inspect lib/file.ex:42 --context
mix reach.inspect Module.function/arity --data --variable user
mix reach.inspect Module.function/arity --why Other.Module.call/1
mix reach.inspect Module.function/arity --graph
```

## `mix reach.trace`

Data-flow and slicing workflows.

```bash
mix reach.trace --from conn.params --to Repo
mix reach.trace --from conn.params --to System.cmd --all
mix reach.trace --variable token --in MyApp.Auth.login/2
mix reach.trace lib/my_app/auth.ex:42 --forward
```

## `mix reach.check`

CI and release-safety checks.

```bash
mix reach.check --arch
mix reach.check --changed --base main
mix reach.check --dead-code
mix reach.check --smells
mix reach.check --candidates
```

## `mix reach.otp`

OTP/process analysis.

```bash
mix reach.otp
mix reach.otp MyApp.Worker
mix reach.otp --concurrency
mix reach.otp --format json
```

## Removed commands

Use the canonical replacements:

| Removed | Use instead |
|---|---|
| `mix reach.modules` | `mix reach.map --modules` |
| `mix reach.coupling` | `mix reach.map --coupling` |
| `mix reach.hotspots` | `mix reach.map --hotspots` |
| `mix reach.depth` | `mix reach.map --depth` |
| `mix reach.effects` | `mix reach.map --effects` |
| `mix reach.boundaries` | `mix reach.map --boundaries` |
| `mix reach.xref` | `mix reach.map --data` |
| `mix reach.deps TARGET` | `mix reach.inspect TARGET --deps` |
| `mix reach.impact TARGET` | `mix reach.inspect TARGET --impact` |
| `mix reach.slice TARGET` | `mix reach.trace TARGET` |
| `mix reach.flow ...` | `mix reach.trace ...` |
| `mix reach.dead_code` | `mix reach.check --dead-code` |
| `mix reach.smell` | `mix reach.check --smells` |
| `mix reach.graph TARGET` | `mix reach.inspect TARGET --graph` |
| `mix reach.concurrency` | `mix reach.otp --concurrency` |
