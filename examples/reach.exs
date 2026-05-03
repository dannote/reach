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
  tests: [
    hints: [
      {"lib/reach/visualize/**",
       ["test/visualize/block_quality_test.exs", "test/visualize_test.exs"]},
      {"lib/reach/frontend/**", ["test/ir/frontend_elixir_test.exs", "test/frontend"]},
      {"lib/mix/tasks/**", ["test/cli"]},
      {"lib/reach/otp/**", ["test/otp_test.exs"]}
    ]
  ]
]
