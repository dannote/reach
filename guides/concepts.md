# Concepts

Reach translates source code into an intermediate representation, builds control/data/call relationships, and combines them into a program dependence graph.

## Control flow

Control-flow graphs show branch structure inside functions. Reach keeps function CFGs acyclic and uses block-quality checks to ensure rendered blocks cover source lines without duplicates.

## Call graph

The call graph connects caller and callee functions. Reach uses it for dependency trees, impact analysis, module coupling, hotspots, and why-path explanations.

## Data flow

Data-flow edges track definitions, uses, parameters, returns, and cross-function value movement. Trace commands use these edges for taint and variable workflows.

## Effects

Reach classifies calls into effect categories such as pure, IO, read, write, send, receive, exception, NIF, and unknown. Effect evidence powers boundaries, smells, and refactoring candidates.

## Smells

Reach detects structural code smells in two layers:

**Pattern smells** use ExAST's `~p` sigil to match source-level AST patterns — pipe anti-patterns, collection idiom misuse, config phase mistakes. These run per-file via Sourceror zipper traversal.

**Semantic smells** use Reach's own IR with effects, data flow, call graph, and clone evidence — redundant computation, loop anti-patterns, dual key access, fixed-shape maps, behaviour candidates, return-contract drift.

Pattern smells are declared with a DSL:

```elixir
use Reach.Smell.PatternCheck

smell ~p[Enum.reverse(_) |> hd()], :suboptimal,
      "traverses twice; use List.last/1"

smell(
  from(~p[Enum.drop(_, amount) |> Enum.take(_)]) |> where(not match?({:-, _, [_]}, ^amount)),
  :eager_pattern,
  "use Enum.slice/3"
)
```

Semantic smells use the standard `use Reach.Smell.Check` behaviour with IR helpers like `inside_loop?/2`, `callback_body/1`, and `statement_pairs/1`.

## Clone analysis

Optional clone evidence (via ExDNA) enriches semantic smell confidence. Clone families inform structural consistency checks: return-contract drift, side-effect order drift, map-contract drift, validation drift, and behaviour extraction candidates.

## Plugins

Plugins extend Reach with framework-specific semantics: effect classification, trace presets, behaviour labels, visualization filtering, and graph edges. Built-in plugins auto-detect Phoenix, Ecto, Oban, Ash, GenStage, Jido, and OpenTelemetry. Language frontends (JavaScript/Gleam) are also plugin-discovered.

## OTP analysis

OTP checks identify GenServer state access, GenStatem transitions, missing handlers, dead replies, supervision, process dictionary/ETS coupling, and cross-process resource sharing.
