# Reach Canonical Commands: 20-Codebase Validation

Validation date: 2026-04-27

Branch: `command-roadmap-implementation`

## Scope

Validated the canonical command work against 20 additional real Elixir codebases, including the Jido ecosystem and an AI-generated/AI-heavy umbrella project.

Commands exercised per repository:

```bash
mix reach.map --format json --top 5
mix reach.map --data --format json --top 5
mix reach.inspect <hotspot file:line> --context --format json
mix reach.inspect <hotspot file:line> --candidates --format json
mix reach.check --candidates --format json
mix reach.check --arch --format json
```

The architecture check used this minimal permissive policy for smoke validation:

```elixir
[
  layers: [all: "**"],
  forbidden_deps: [],
  allowed_effects: [],
  test_hints: []
]
```

Artifacts:

```text
/tmp/reach-validation-20
/tmp/reach-validation-20/summary.csv
```

## Summary

All 20 repositories passed command execution and JSON shape validation.

| Repo | Status | Functions | Modules | Hotspot |
|---|---:|---:|---:|---|
| `agentjido/jido` | ok | 1322 | 170 | `lib/jido/error.ex:328` |
| `agentjido/jido_ai` | ok | 2074 | 174 | `lib/jido_ai/tool_adapter.ex:161` |
| `agentjido/jido_harness` | ok | 128 | 40 | `lib/jido_harness/exec.ex:86` |
| `agentjido/jido_shell` | ok | 393 | 50 | `lib/jido_shell/environment/sprite.ex:203` |
| `agentjido/jido_vfs` | ok | 442 | 55 | `lib/jido_vfs/relative_path.ex:14` |
| `agentjido/jido_claude` | ok | 175 | 37 | `lib/jido_claude/executor/shell.ex:504` |
| `agentjido/jido_codex` | ok | 98 | 23 | `lib/jido_codex/mapper.ex:14` |
| `agentjido/jido_gemini` | ok | 39 | 19 | `lib/jido_gemini/mapper.ex:131` |
| `robertohluna/jido_claw` | ok | 837 | 193 | `lib/jido_claw/forge/bootstrap.ex:5` |
| `HackTuah/HackTUI-Hermes-Jido` | ok | 513 | 128 | `apps/hacktui_tui/lib/hacktui_tui/live_dashboard_view.ex:584` |
| `livebook-dev/livebook` | ok | 3341 | 267 | `lib/livebook_web/live/session_live.ex:217` |
| `plausible/analytics` | ok | 3111 | 491 | `lib/plausible_web/controllers/api/stats_controller.ex:1393` |
| `supabase/realtime` | ok | 917 | 275 | `lib/realtime_web/channels/realtime_channel/broadcast_handler.ex:25` |
| `ash-project/ash` | ok | 4227 | 648 | `lib/ash/query/aggregate.ex:214` |
| `ash-project/ash_postgres` | ok | 600 | 94 | `lib/data_layer.ex:1114` |
| `absinthe-graphql/absinthe` | ok | 1126 | 270 | `lib/absinthe/blueprint/input.ex:92` |
| `surface-ui/surface` | ok | 874 | 135 | `lib/surface/compiler.ex:368` |
| `nerves-project/nerves` | ok | 336 | 50 | `lib/nerves/artifact/resolvers/github_api.ex:79` |
| `dashbitco/broadway` | ok | 175 | 22 | `lib/broadway/topology.ex:479` |
| `commanded/commanded` | ok | 450 | 66 | `lib/commanded/event_store/adapters/in_memory.ex:470` |

## Bugs found

### Umbrella projects were not scanned

`HackTUI-Hermes-Jido` initially reported zero functions and zero modules. Manual inspection showed the project stores code under `apps/*/lib/**/*.ex`.

Fix:

```text
ebf4977 Analyze umbrella app sources
```

`Reach.Project.from_mix_project/1` now scans:

```text
lib/**/*.ex
apps/*/lib/**/*.ex
src/**/*.erl
apps/*/src/**/*.erl
```

### `reach.inspect file:line` could resolve the wrong function

In Ecto, inspecting `lib/ecto/query/builder.ex:84` initially resolved to another `escape/5` with the same MFA shape in another file. This happened because the file-line target was converted to MFA and then resolved by function identity.

Fix:

```text
6192fbf Resolve inspect file targets exactly
```

File-line targets now preserve the exact function node returned by `Project.find_function_at_location/3`.

## Manual false-positive audit

### Hotspots

Hotspots are mostly reliable as impact/risk indicators, not automatic refactoring requests.

Representative review:

| Repo | Finding | Classification | Notes |
|---|---|---|---|
| Jido | `Jido.Error.validation_error/2`, 45 callers | true positive, not necessarily refactorable | High fan-in factory/helper; useful change-risk signal. |
| Jido AI | `Jido.AI.ToolAdapter.to_action_map/1` | true positive | Tool adapter normalization is a meaningful risk point. |
| HackTUI-Hermes-Jido | `normalize_flow/1`, 42 branches | true positive, actionable | Large normalization function with many fallback keys; very likely AI-slop style. Good extract/normalize candidate. |
| Ash | `Ash.Query.Aggregate.new/4`, 37 branches, 11 callers | true positive, high-risk | Large constructor/validator. Candidate needs careful proof; not a drive-by refactor. |
| Livebook | `LivebookWeb.SessionLive.handle_event/3`, 33 branches | true positive, project-pattern dependent | Large multi-clause LiveView event handler. A hotspot, but splitting may not align with project style. |
| Plausible | `breakdown_metrics/2`, 20 callers | true positive as impact signal | Low branch count; primarily a high fan-in API/controller helper. |

Conclusion: hotspot detection is useful and low false-positive when interpreted as “change risk.” It should not be presented as “must refactor.”

### `extract_pure_region` candidates

Representative review:

| Repo | Finding | Classification | Notes |
|---|---|---|---|
| HackTUI-Hermes-Jido | `normalize_flow/1` | true positive, actionable | Strong candidate. Pure normalization, many key fallbacks, clear extraction opportunities. |
| Ash | `Ash.Query.Aggregate.new/4` | true positive, high-risk | Branch-heavy and data-heavy. Extraction possible but requires fixtures/goldens around aggregate behavior. |
| Livebook | `handle_event/3` | true positive, but needs project policy | Many clauses are already separated by function heads. Candidate should be treated as “large dispatch surface,” not automatically extract a helper. |

False-positive risk: medium. Current candidate says “look for a pure region,” which is appropriately cautious. It should not suggest a specific edit yet.

### `isolate_effects` candidates

Representative review:

| Repo | Finding | Classification | Notes |
|---|---|---|---|
| HackTUI-Hermes-Jido | `Replay.Loader.load_fixture!/1` | true positive but small | File IO + JSON parse + envelope construction. Splitting pure parse from file read is reasonable, but function is small. |
| HackTUI-Hermes-Jido | `Runtime.build_and_open_case/5` | likely true positive | Mixed filesystem/runtime behavior; good candidate for separating planning from execution. |
| Jido AI | `Signal.Helpers.normalize_error/4` | false positive for “isolate effects” if only `unknown`/exception-like behavior | Mostly pure normalization with `Code.ensure_loaded?` and exception/message handling. Better classified as normalization complexity, not side-effect isolation. |
| Phoenix | `CodeReloader.Server.handle_call/3` | true positive but expected OTP style | Mixed effects are normal for GenServer callbacks. Should be lower priority unless policy says callbacks should delegate. |

False-positive risk was medium-high when `unknown` was included. This was fixed after audit: `isolate_effects` now requires at least two concrete non-unknown effects. `unknown` still appears in general effect summaries, but no longer creates an isolation candidate by itself.

### `break_cycle` candidates

Representative review:

| Repo | Finding | Classification | Notes |
|---|---|---|---|
| Jido | `Jido <-> Jido.Agent.WorkerPool` | graph true positive, architectural judgment required | Public facade and worker pool mutually refer. May be acceptable API/facade pattern. |
| Ash | `Ash.DataLayer <-> Ash.Sort` | graph true positive, needs project policy | Could be real architectural coupling, but Ash has dense domain modules where cycles may be accepted. |
| Livebook | `Livebook.Session <-> Livebook.Session.Worker` | graph true positive, likely intentional | Process/session boundary may intentionally be paired. |
| Plausible | `Plausible.Stats <-> Plausible.Stats.Aggregate` | graph true positive, likely boundary smell | Stats facade/submodule cycles are plausible refactor candidates. |

False-positive risk: high if presented as “bad.” These are true graph cycles, but not always bad design. The wording “candidate” is acceptable, but ranking them above concrete `isolate_effects` candidates can be misleading.

Change made after review:

```text
568c114 Prefer minimal cycle candidates
```

Cycle candidates now suppress supersets when a smaller cycle already explains the issue. This reduced noisy long-cycle candidates substantially, but the remaining two-module cycles still require project policy/context.

Additional tuning after audit:

```text
cedb65b Discount unknown effects in candidates
```

This removed cases such as `Ash.Query.Aggregate.new/4` being labeled `isolate_effects` only because it had `exception + unknown`. It remains an `extract_pure_region` candidate, which is the better classification.

Follow-up review found another precision issue: expected effect boundary functions, especially OTP callbacks, application `start/2`, LiveView callbacks, and Mix task files, were being reported as `isolate_effects`. These functions are commonly side-effect boundaries by design. Candidate generation now suppresses `isolate_effects` for those entrypoint shapes while still allowing `extract_pure_region` for branch-heavy callbacks.

## AI-generated / AI-heavy observations

`HackTUI-Hermes-Jido` is the clearest AI-slop validation case.

Good signals surfaced:

- `normalize_flow/1` has 42 branches and many alternate key names.
- The code has defensive normalization/fallback style:
  - `"src"` / `:src`
  - `"source_ip"` / `:source_ip`
  - `"dst"` / `:dst`
  - `"destination_ip"` / `:destination_ip`
  - multiple site/host/SNI/DNS fallbacks
- `reach.inspect --data` shows high variable/use pressure in that function.
- `reach.check --candidates` surfaces mixed IO/read/unknown functions in replay/runtime modules.

Assessment: Reach is effective at surfacing AI-slop-shaped complexity, especially branch-heavy normalization and mixed effect boundaries.

## Accuracy summary

| Signal | Precision | Notes |
|---|---|---|
| Command execution / JSON schema | high | 20/20 passed after umbrella fix. |
| File-line target resolution | high after fix | Verified against real hotspot locations. |
| Hotspots as change-risk indicators | high | Mostly accurate; not always refactoring candidates. |
| Data-flow density | medium-high | Top functions are plausible, but edge counts need explanation in docs. |
| `extract_pure_region` candidates | medium | Good as advisory. Needs future region extraction to become precise. |
| `isolate_effects` candidates | medium-high after fixes | `unknown` no longer inflates candidates; known callbacks and Mix task files are suppressed as expected effect boundaries. |
| `break_cycle` candidates | medium-low without project policy | Graph-true but actionability varies. Minimal-cycle filtering improved noise. |
| `.reach.exs` permissive policy | high | Validated across all 20 repos. |

## Recommendations before release

1. Keep wording advisory. Do not say “smell” or “must fix” for candidates.
2. `isolate_effects` now requires two concrete effects excluding `unknown`; preserve that rule.
3. `isolate_effects` suppresses known entrypoint/callback shapes; preserve that rule unless `.reach.exs` explicitly opts into callback refactoring.
4. For `break_cycle`, include representative calls in a future iteration.
5. For `break_cycle`, consider ranking cycles below concrete local candidates unless `.reach.exs` has layer policy.
5. Document that hotspots mean “change risk,” not automatically “bad code.”
6. Preserve the file-line resolution fix; it caught a real correctness issue.
7. Preserve umbrella source scanning; it caught a real coverage issue.

## Verdict

The canonical commands are stable enough for a major-release branch from a crash/shape/coverage perspective. The most important correctness bugs found during validation were fixed.

Refactoring candidates should remain explicitly advisory. Hotspots and data-flow summaries are reliable as navigation and risk signals. Cycle candidates are true graph facts but require project architecture context before action.
