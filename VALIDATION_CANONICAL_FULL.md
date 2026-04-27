# Canonical CLI Full Real-Codebase Validation

Validation date: 2026-04-27

Branch: `command-roadmap-implementation`

## Scope

Validated every canonical command family and submode against 20 real Elixir codebases under `/tmp/reach-validation-repos`:

- `agentjido/jido`
- `agentjido/jido_ai`
- `agentjido/jido_harness`
- `agentjido/jido_shell`
- `agentjido/jido_vfs`
- `agentjido/jido_claude`
- `agentjido/jido_codex`
- `agentjido/jido_gemini`
- `robertohluna/jido_claw`
- `HackTuah/HackTUI-Hermes-Jido`
- `livebook-dev/livebook`
- `plausible/analytics`
- `supabase/realtime`
- `ash-project/ash`
- `ash-project/ash_postgres`
- `absinthe-graphql/absinthe`
- `surface-ui/surface`
- `nerves-project/nerves`
- `dashbitco/broadway`
- `commanded/commanded`

Artifacts:

```text
/tmp/reach-canonical-full-validation
/tmp/reach-canonical-full-validation/results.csv
```

Validation script:

```text
/tmp/reach_validate_canonical_full.sh
```

## Covered command surface

For every repo, the validation uses a real hotspot `file:line` target from `mix reach.map --format json --top 5`, then runs:

### `mix reach.map`

- default text
- oneline
- JSON envelope
- `--modules`
- `--hotspots`
- `--coupling`
- `--effects`
- `--boundaries`
- `--depth`
- `--data`
- `--modules --sort complexity`

### `mix reach.inspect TARGET`

- `--context` JSON and text
- `--deps` JSON
- `--impact` JSON
- `--data` JSON and text
- `--candidates` JSON
- `--slice` JSON
- `--graph`
- `--data --graph`

### `mix reach.trace`

- `--variable state --format json`
- `--from params --to Repo --format json`
- `--backward TARGET --format json`
- `--forward TARGET --format json`
- positional target text slicing
- `--backward TARGET --graph`

### `mix reach.check`

- default text
- `--candidates --format json --top 5`
- `--changed --base HEAD --format json`
- `--dead-code --format json`
- `--smells --format json`
- `--arch --format json` with a permissive temporary `.reach.exs`

### `mix reach.otp`

- default text
- JSON
- `--concurrency --format json`
- `--graph`

### Removed legacy commands

- `mix reach.modules` raises with `mix reach.map --modules` guidance
- `mix reach.deps TARGET` raises with `mix reach.inspect TARGET --deps` guidance

JSON outputs are checked with `jq`; canonical JSON envelopes are checked for the expected `command` value.

## Result

All checks passed across all 20 repositories.

```text
failures=0
```

## Bugs found and fixed during this validation

### Boxart failed on non-ASCII source snippets

`mix reach.inspect lib/livebook_web/live/session_live.ex:217 --graph` crashed in `boxart` while rendering a Livebook heredoc containing curly quotes/non-ASCII codepoints.

Fix:

```text
31baa07 Fix graph rendering and speed taint tracing
```

`Reach.CLI.BoxartGraph` now sanitizes source snippets passed to boxart code nodes, preserving tabs/newlines/ASCII and replacing unsupported codepoints with `?`.

### Taint tracing was too slow on large codebases

`mix reach.trace --from params --to Repo --format json` took ~130s on `plausible/analytics` because the implementation checked every source/sink pair with repeated graph reachability.

Fix:

```text
31baa07 Fix graph rendering and speed taint tracing
```

Taint tracing now computes reachable nodes once per source, intersects with sink IDs, and caps rendered paths at 50.

After the fix, the same validation step on `plausible/analytics` completed in ~3s.

## Slowest checks after fixes

From `/tmp/reach-canonical-full-validation/results.csv`:

| Repo | Check | Seconds |
|---|---|---:|
| `ash` | `map_data_json` | 35 |
| `livebook` | `inspect_graph` | 15 |
| `ash` | `map_text` | 13 |
| `ash` | `map_json` | 11 |
| `livebook` | `map_data_json` | 10 |
| `ash` | `inspect_context_text` | 10 |
| `ash` | `otp_text` | 9 |
| `ash` | `otp_graph` | 9 |
| `ash` | `otp_json` | 8 |
| `analytics` | `map_data_json` | 8 |

`ash` is the main remaining performance stress case, especially project-wide data-flow summaries.

## Final local validation

After real-codebase validation, full CI passed:

```bash
mix ci
```

```text
format: OK
js.check: OK
credo --strict: no issues
ex_dna: no code duplication detected
reach.check --arch: OK
dialyzer: 0 errors
test: 471 tests, 0 failures
```
