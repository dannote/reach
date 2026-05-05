# Validation

Reach 2.x is validated at multiple levels.

## Project gates

```bash
mix compile --force --warnings-as-errors
mix ci
mix docs
mix hex.build
```

`mix ci` includes formatting, JavaScript checks, Credo/ExSlop, ExDNA duplication checks, architecture policy, Dialyzer, and tests.

## Canonical CLI validation

The canonical command validation script exercises Reach, Phoenix, Ecto, and Oban command paths and checks JSON purity.

```bash
/tmp/reach_validate_canonical_full.sh
```

Expected result:

```text
failures=0
```

## ProgramFacts oracle validation

Reach uses ProgramFacts-generated Elixir projects and oracle facts to validate call graphs, layouts, data flow, effects, architecture policies, branch/control-flow policies, and syntax policies.

## Block quality

Visualization changes must preserve source coverage, disjoint block ranges, branch boundaries, clause blocks, non-empty labels, connected exits, and no duplicated lines.

```bash
mix test test/reach/visualize/block_quality_test.exs
```
