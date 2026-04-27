# Example Reach architecture policy.
# Copy to .reach.exs and adjust layer names/patterns for your project.
[
  layers: [
    cli: "Mix.Tasks.*",
    public_api: ["Reach", "Reach.Project"],
    frontend: "Reach.Frontend.*",
    ir: "Reach.IR.*",
    analysis: [
      "Reach.ControlFlow",
      "Reach.DataDependence",
      "Reach.ControlDependence",
      "Reach.Dominator",
      "Reach.SystemDependence",
      "Reach.Effects"
    ],
    visualization: "Reach.Visualize.*",
    plugins: "Reach.Plugins.*"
  ],
  forbidden_deps: [
    {:ir, :cli},
    {:analysis, :cli},
    {:frontend, :visualization},
    {:frontend, :cli},
    {:ir, :visualization}
  ],
  public_api: [
    "Reach",
    "Reach.Project"
  ],
  internal: [
    "Reach.IR.*",
    "Reach.Visualize.*"
  ],
  internal_callers: [
    {"Reach.IR.*", ["Reach", "Reach.*"]},
    {"Reach.Visualize.*", ["Reach.Visualize", "Reach.Visualize.*", "Mix.Tasks.Reach"]}
  ],
  allowed_effects: [
    {"Reach.IR.*", [:pure, :unknown]},
    {"Reach.ControlFlow", [:pure, :unknown]},
    {"Reach.Dominator", [:pure, :unknown]},
    {"Mix.Tasks.*", [:pure, :io, :read, :write, :unknown]}
  ],
  test_hints: [
    {"lib/reach/visualize/**",
     [
       "test/visualize/block_quality_test.exs",
       "test/visualize_test.exs"
     ]},
    {"lib/reach/frontend/elixir.ex",
     [
       "test/ir/frontend_elixir_test.exs"
     ]},
    {"lib/mix/tasks/**",
     [
       "test/mix_task_canonical_test.exs"
     ]}
  ]
]
