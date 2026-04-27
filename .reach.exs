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
  forbidden_deps: [
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
  ],
  allowed_effects: [
    {"Reach.IR.*", [:pure, :unknown]},
    {"Reach.ControlFlow", [:pure, :unknown]},
    {"Reach.Dominator", [:pure, :unknown]},
    {"Reach.DataDependence", [:pure, :unknown]},
    {"Reach.ControlDependence", [:pure, :unknown]},
    {"Reach.SystemDependence", [:pure, :unknown]},
    {"Reach.Effects", [:pure, :unknown]},
    {"Reach.CLI.Format", [:pure, :unknown]}
  ],
  public_api: [],
  internal: [],
  internal_callers: [],
  test_hints: [
    {"lib/reach/visualize/**",
     ["test/visualize/block_quality_test.exs", "test/visualize_test.exs"]},
    {"lib/reach/frontend/**", ["test/ir/frontend_elixir_test.exs", "test/frontend"]},
    {"lib/mix/tasks/**", ["test/mix_task_canonical_test.exs"]},
    {"lib/reach/otp/**", ["test/reach/otp"]}
  ]
]
