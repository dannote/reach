[
  layers: [
    cli_entrypoints: "Mix.Tasks.*",
    cli_commands: "Reach.CLI.Commands.*",
    cli_render: "Reach.CLI.Render.*",
    cli_support: [
      "Reach.CLI.Project",
      "Reach.CLI.Options",
      "Reach.CLI.Pipe",
      "Reach.CLI.Deprecation",
      "Reach.CLI.Format",
      "Reach.CLI.JSONEnvelope",
      "Reach.CLI.BoxartGraph",
      "Reach.CLI.Requirements"
    ],
    core: "Reach",
    frontend: "Reach.Frontend.*",
    ir: "Reach.IR.*",
    project_query: "Reach.Project.Query",
    inspect: "Reach.Inspect.*",
    trace: "Reach.Trace.*",
    check: "Reach.Check.*",
    smell: "Reach.Smell.*",
    map: "Reach.Map.*",
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
      {:cli_entrypoints, :cli_render},
      {:cli_entrypoints, :core},
      {:cli_entrypoints, :frontend},
      {:cli_entrypoints, :ir},
      {:cli_entrypoints, :inspect},
      {:cli_entrypoints, :trace},
      {:cli_entrypoints, :check},
      {:cli_entrypoints, :smell},
      {:cli_entrypoints, :analysis},
      {:cli_entrypoints, :otp},
      {:cli_entrypoints, :visualization},
      {:cli_entrypoints, :plugins},
      {:cli_commands, :cli_entrypoints},
      {:cli_support, :cli_entrypoints},
      {:cli_support, :cli_commands},
      {:cli_render, :cli_entrypoints},
      {:cli_render, :cli_commands},
      {:ir, :cli_entrypoints},
      {:ir, :cli_commands},
      {:ir, :cli_render},
      {:ir, :cli_support},
      {:project_query, :cli_entrypoints},
      {:project_query, :cli_commands},
      {:project_query, :cli_render},
      {:project_query, :cli_support},
      {:frontend, :cli_entrypoints},
      {:frontend, :cli_commands},
      {:frontend, :cli_render},
      {:frontend, :cli_support},
      {:analysis, :cli_entrypoints},
      {:analysis, :cli_commands},
      {:analysis, :cli_render},
      {:analysis, :cli_support},
      {:inspect, :cli_entrypoints},
      {:inspect, :cli_commands},
      {:inspect, :cli_render},
      {:inspect, :cli_support},
      {:trace, :cli_entrypoints},
      {:trace, :cli_commands},
      {:trace, :cli_render},
      {:trace, :cli_support},
      {:smell, :cli_entrypoints},
      {:smell, :cli_commands},
      {:smell, :cli_render},
      {:smell, :cli_support},
      {:map, :cli_entrypoints},
      {:map, :cli_commands},
      {:map, :cli_render},
      {:map, :cli_support},
      {:check, :cli_entrypoints},
      {:check, :cli_commands},
      {:check, :cli_render},
      {:check, :cli_support},
      {:otp, :cli_entrypoints},
      {:otp, :cli_commands},
      {:otp, :cli_render},
      {:otp, :cli_support},
      {:visualization, :cli_entrypoints},
      {:visualization, :cli_commands},
      {:visualization, :cli_render},
      {:visualization, :cli_support},
      {:plugins, :cli_entrypoints},
      {:plugins, :cli_commands},
      {:plugins, :cli_render},
      {:plugins, :cli_support}
    ]
  ],
  source: [
    forbidden_modules: [
      "Reach.CLI.Analyses.*",
      "Reach.CLI.TaskRunner",
      "Reach.CLI.TaskRunner.*"
    ],
    forbidden_files: [
      "lib/reach/cli/analyses/**",
      "lib/reach/cli/task_runner.ex"
    ]
  ],
  calls: [
    forbidden: [
      {"Reach.CLI.Commands.*", ["IO.puts", "Jason.encode!", "Reach.CLI.Format.render"]}
    ]
  ],
  effects: [
    allowed: [
      {"Reach.IR.*", [:pure, :unknown, :write]},
      {"Reach.ControlFlow", [:pure, :unknown]},
      {"Reach.Dominator", [:pure, :unknown]},
      {"Reach.DataDependence", [:pure, :unknown]},
      {"Reach.ControlDependence", [:pure, :unknown]},
      {"Reach.SystemDependence", [:pure, :unknown]},
      {"Reach.Effects", [:pure, :unknown, :io, :read, :write]},
      {"Reach.CLI.Format", [:pure, :unknown, :io, :read, :write]},
      {"Reach.CLI.Options", [:pure, :unknown]},
      {"Reach.CLI.Pipe", [:pure, :unknown, :write, :io, :exception]}
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
  clone_analysis: [
    provider: :ex_dna,
    min_mass: 30,
    min_similarity: 1.0,
    max_clones: 50
  ],
  smells: [
    fixed_shape_map: [
      min_keys: 3,
      min_occurrences: 3,
      evidence_limit: 10
    ],
    behaviour_candidate: [
      min_modules: 3,
      min_callbacks: 3,
      module_display_limit: 8,
      callback_display_limit: 8
    ]
  ],
  tests: [
    hints: [
      {"lib/reach/visualize/**",
       ["test/reach/visualize/block_quality_test.exs", "test/reach/visualize/visualize_test.exs"]},
      {"lib/reach/frontend/**",
       ["test/reach/ir/frontend_elixir_test.exs", "test/reach/frontend"]},
      {"lib/mix/tasks/**", ["test/reach/cli"]},
      {"lib/reach/cli/**", ["test/reach/cli"]},
      {"lib/reach/check/**", ["test/reach/check", "test/reach/smell/smell_test.exs"]},
      {"lib/reach/inspect/**", ["test/reach/cli"]},
      {"lib/reach/trace/**", ["test/reach/cli", "test/reach/project/query_test.exs"]},
      {"lib/reach/smell/**", ["test/reach/smell/smell_test.exs"]},
      {"lib/reach/otp/**", ["test/reach/otp/otp_test.exs"]}
    ]
  ]
]
