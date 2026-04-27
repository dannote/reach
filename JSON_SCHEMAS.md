# Reach Canonical JSON Envelopes

These schemas document the stable top-level shapes for the canonical dotted commands. Fields may be added over time, but existing keys should remain compatible.

## `mix reach.map --format json`

```json
{
  "command": "reach.map",
  "summary": {
    "modules": 67,
    "functions": 1109,
    "call_graph_vertices": 2863,
    "call_graph_edges": 10253,
    "graph_nodes": 63873,
    "graph_edges": 66646,
    "effects": {
      "pure": 1109,
      "io": 140,
      "read": 35,
      "write": 64,
      "unknown": 1109
    }
  },
  "sections": {
    "modules": [
      {
        "name": "Reach.Project",
        "file": "lib/reach/project.ex",
        "functions": 21,
        "public": 5,
        "private": 16,
        "complexity": 17
      }
    ],
    "hotspots": [
      {
        "function": "Reach.Frontend.Elixir.translate/3",
        "file": "lib/reach/frontend/elixir.ex",
        "line": 54,
        "branches": 17,
        "callers": 8,
        "score": 136
      }
    ],
    "coupling": {
      "modules": [
        {
          "name": "Reach.IR",
          "file": "lib/reach/ir.ex",
          "afferent": 38,
          "efferent": 1,
          "instability": 0.03
        }
      ],
      "cycles": [
        {"modules": ["Reach", "Reach.SystemDependence"]}
      ]
    },
    "boundaries": [
      {
        "function": "Reach.Frontend.Elixir.translate/3",
        "file": "lib/reach/frontend/elixir.ex",
        "line": 54,
        "effects": ["read", "write"]
      }
    ]
  }
}
```

When a focused section is requested, `sections` contains only that key:

```bash
mix reach.map --data --format json
```

```json
{
  "command": "reach.map",
  "summary": {},
  "sections": {
    "data": {
      "total_data_edges": 12345,
      "top_functions": [
        {
          "function": "Reach.Frontend.Elixir.translate/3",
          "file": "lib/reach/frontend/elixir.ex",
          "line": 54,
          "data_edges": 532
        }
      ]
    }
  }
}
```

## `mix reach.inspect TARGET --context --format json`

```json
{
  "command": "reach.inspect",
  "target": "Reach.to_dot/1",
  "location": {
    "file": "lib/reach.ex",
    "line": 548
  },
  "effects": ["pure", "unknown"],
  "deps": {
    "callers": ["Mix.Tasks.Reach.render_dot/2"],
    "callees": [
      {
        "id": "Graph.to_dot/1",
        "depth": 1,
        "children": []
      }
    ]
  },
  "impact": {
    "direct_callers": ["Mix.Tasks.Reach.render_dot/2"],
    "transitive_callers": ["Mix.Tasks.Reach.render_dot/2", "Mix.Tasks.Reach.run/1"]
  },
  "data": {
    "definitions": [
      {"name": "g", "role": "definition", "file": "lib/reach.ex", "line": 549}
    ],
    "uses": [
      {"name": "g", "role": "use", "file": "lib/reach.ex", "line": 550}
    ],
    "returns": [
      {"kind": "clause", "file": "lib/reach.ex", "line": 548}
    ]
  }
}
```

## `mix reach.inspect TARGET --candidates --format json`

```json
{
  "command": "reach.inspect",
  "target": "Reach.Frontend.Elixir.translate/3",
  "candidates": [
    {
      "id": "R2-001",
      "kind": "isolate_effects",
      "target": "Reach.Frontend.Elixir.translate/3",
      "file": "lib/reach/frontend/elixir.ex",
      "line": 54,
      "benefit": "medium",
      "risk": "medium",
      "confidence": "medium",
      "actionability": "review_effect_order",
      "evidence": ["mixed_effects"],
      "effects": ["read", "write"],
      "proof": [
        "Preserve side-effect order exactly.",
        "Extract only pure decision/preparation code first.",
        "Run tests covering both success and error paths."
      ],
      "suggestion": "Split pure decision logic from side-effect execution while preserving effect order."
    }
  ],
  "note": "Candidates are advisory. Prove behavior preservation before editing."
}
```

Candidate `kind` values currently emitted:

- `extract_pure_region`
- `isolate_effects`
- `break_cycle`
- `introduce_boundary`

Project-wide candidate output may include all of these kinds. Every candidate includes:

- `confidence` — `low`, `medium`, or `high`
- `actionability` — short review state such as `needs_region_proof`, `review_effect_order`, `needs_project_policy`, or `policy_violation`
- `proof` — checks an agent or reviewer must satisfy before editing

Cycle candidates also include `representative_calls` with source locations for edges participating in the cycle.

## `mix reach.check --arch --format json`

```json
{
  "config": ".reach.exs",
  "status": "ok",
  "violations": []
}
```

Violation shapes:

```json
{
  "type": "forbidden_dependency",
  "caller_module": "Reach.Frontend.Elixir",
  "caller_layer": "frontend",
  "callee_module": "Reach.Visualize",
  "callee_layer": "visualization",
  "file": "lib/reach/frontend/elixir.ex",
  "line": 42,
  "call": "Reach.Visualize.to_json/1"
}
```

```json
{
  "type": "public_api_boundary",
  "caller_module": "Mix.Tasks.MyTool",
  "callee_module": "Reach.Internal.Helper",
  "file": "lib/mix/tasks/my_tool.ex",
  "line": 42,
  "call": "Reach.Internal.Helper.run/1",
  "rule": "calls into non-public API module"
}
```

```json
{
  "type": "internal_boundary",
  "caller_module": "Mix.Tasks.MyTool",
  "callee_module": "Reach.IR.Node",
  "file": "lib/mix/tasks/my_tool.ex",
  "line": 42,
  "call": "Reach.IR.Node.id/0",
  "rule": "caller is not allowed to call configured internal module"
}
```

```json
{
  "type": "config_error",
  "key": "layers",
  "message": "expected keyword list of layer: patterns"
}
```

```json
{
  "type": "layer_cycle",
  "layers": ["analysis", "frontend"]
}
```

```json
{
  "type": "effect_policy",
  "module": "Reach.ControlFlow",
  "function": "build/1",
  "allowed_effects": ["pure"],
  "actual_effects": ["pure", "read"],
  "disallowed_effects": ["read"],
  "file": "lib/reach/control_flow.ex",
  "line": 28
}
```

## `mix reach.check --changed --base main --format json`

```json
{
  "base": "main",
  "changed_files": ["lib/reach/frontend/elixir.ex"],
  "changed_functions": [
    {
      "id": "Reach.Frontend.Elixir.translate/3",
      "file": "lib/reach/frontend/elixir.ex",
      "line": 54,
      "effects": ["pure", "read", "write", "unknown"],
      "direct_callers": ["Reach.Frontend.Elixir.parse/2"],
      "direct_caller_count": 1
    }
  ],
  "public_api_changes": [
    {
      "id": "Reach.file_to_graph/1",
      "file": "lib/reach.ex",
      "line": 120,
      "public_api": true
    }
  ],
  "suggested_tests": ["test/ir/frontend_elixir_test.exs"]
}
```

## `mix reach.check --candidates --format json`

Use `--top N` to limit the number of returned candidates.

```json
{
  "candidates": [
    {
      "id": "R3-001",
      "kind": "break_cycle",
      "target": "Reach -> Reach.SystemDependence",
      "benefit": "high",
      "risk": "medium",
      "confidence": "low",
      "actionability": "needs_project_policy",
      "evidence": ["module_dependency_cycle"],
      "modules": ["Reach", "Reach.SystemDependence"],
      "representative_calls": [
        {
          "caller_module": "Reach",
          "callee_module": "Reach.SystemDependence",
          "file": "lib/reach.ex",
          "line": 42,
          "call": "Reach.SystemDependence.build/2"
        }
      ],
      "proof": [
        "Confirm the cycle violates intended architecture before changing code.",
        "Review representative_calls to find the smallest boundary-breaking call.",
        "Prefer moving shared helpers downward over introducing a new abstraction."
      ],
      "suggestion": "Move shared code to a lower-level module or route calls through an existing boundary."
    }
  ],
  "note": "Candidates are advisory. Reach reports graph/effect/architecture evidence; prove behavior preservation before editing."
}
```

## Compatibility notes

Older commands such as `mix reach.modules --format json` keep their historical envelopes. Canonical envelopes apply to the new dotted commands only.
