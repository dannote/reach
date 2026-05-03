# Example Reach architecture policy.
# Copy to .reach.exs and adjust layer names/patterns for your project.
[
  layers: [
    cli: "Mix.Tasks.*",
    cli_support: "Reach.CLI.*",
    core: "Reach",
    frontend: "Reach.Frontend.*",
    ir: "Reach.IR.*",
    analysis: [
      "Reach.ControlFlow",
      "Reach.DataDependence",
      "Reach.ControlDependence",
      "Reach.Dominator",
      "Reach.SystemDependence",
      "Reach.Effects",
      "Reach.HigherOrder"
    ],
    otp: "Reach.OTP.*",
    visualization: "Reach.Visualize.*",
    plugins: ["Reach.Plugin", "Reach.Plugins.*"]
  ],
  deps: [
    forbidden: [
      {:ir, :cli},
      {:ir, :cli_support},
      {:frontend, :cli},
      {:frontend, :cli_support},
      {:analysis, :cli},
      {:analysis, :cli_support},
      {:otp, :cli},
      {:otp, :cli_support},
      {:visualization, :cli},
      {:visualization, :cli_support},
      {:plugins, :cli},
      {:plugins, :cli_support}
    ]
  ],
  source: [
    forbidden_modules: [],
    forbidden_files: []
  ],
  calls: [
    forbidden: []
  ],
  effects: [
    allowed: [
      {"Reach.IR.*", [:pure, :unknown]},
      {"Reach.ControlFlow", [:pure, :unknown]},
      {"Reach.Dominator", [:pure, :unknown]},
      {"Reach.DataDependence", [:pure, :unknown]},
      {"Reach.ControlDependence", [:pure, :unknown]},
      {"Reach.SystemDependence", [:pure, :unknown]},
      {"Reach.Effects", [:pure, :unknown]},
      {"Reach.CLI.Format", [:pure, :unknown]}
    ]
  ],
  boundaries: [
    public: [],
    internal: [],
    internal_callers: []
  ],
  risk: [
    changed: [
      many_direct_callers: 5,
      wide_transitive_callers: 10,
      branch_heavy: 8,
      high_risk_reason_count: 3
    ]
  ],
  candidates: [
    thresholds: [
      mixed_effect_count: 2,
      branchy_function_branches: 8,
      high_risk_direct_callers: 4
    ],
    limits: [
      per_kind: 20,
      representative_calls: 10,
      representative_calls_per_edge: 3
    ]
  ],
  smells: [
    fixed_shape_map: [
      min_keys: 3,
      min_occurrences: 3,
      evidence_limit: 10
    ]
  ],
  tests: [
    hints: [
      {"lib/reach/visualize/**",
       ["test/reach/visualize/block_quality_test.exs", "test/reach/visualize/visualize_test.exs"]},
      {"lib/reach/frontend/**",
       ["test/reach/ir/frontend_elixir_test.exs", "test/reach/frontend"]},
      {"lib/mix/tasks/**", ["test/reach/cli"]},
      {"lib/reach/otp/**", ["test/reach/otp/otp_test.exs"]}
    ]
  ]
]
