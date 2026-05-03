# Contributing

## CLI architecture

Reach uses this boundary:

```text
Mix.Tasks.Reach.*       -> thin entrypoints
Reach.CLI.Commands.*    -> orchestration and mode selection
Reach.CLI.Render.*      -> text, JSON, and file output
Reach.* domain modules  -> analysis/check/trace/OTP/map/smell logic
```

Command modules must not render directly. `.reach.exs` enforces this with `calls[:forbidden]`, and tests scan command modules for direct `IO.puts`, `Jason.encode!`, and `Reach.CLI.Format.render` calls.

## Release checklist

Before release:

```bash
mix compile --force --warnings-as-errors
mix ci
/tmp/reach_validate_canonical_full.sh
mix docs
mix hex.build
```

Do not tag or publish without explicit release approval.
