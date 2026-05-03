defmodule Reach.ConfigTest do
  use ExUnit.Case, async: true

  alias Reach.Config

  test "normalizes grouped policy sections into structs" do
    assert %Config{} =
             config =
             Config.normalize(
               layers: [domain: "MyApp.*"],
               deps: [forbidden: [{:domain, :web}]],
               calls: [forbidden: [{"MyApp.*", ["IO.puts"]}]],
               effects: [allowed: [{"MyApp.Pure.*", [:pure]}]],
               boundaries: [
                 public: ["MyApp.Accounts"],
                 internal: ["MyApp.Accounts.Internal.*"],
                 internal_callers: [{"MyApp.Accounts.Internal.*", ["MyApp.Accounts"]}]
               ],
               tests: [hints: [{"lib/my_app/**", ["test/my_app"]}]],
               source: [
                 forbidden_modules: ["MyApp.Legacy.*"],
                 forbidden_files: ["lib/my_app/legacy/**"]
               ],
               risk: [
                 changed: [
                   many_direct_callers: 4,
                   wide_transitive_callers: 9,
                   branch_heavy: 7,
                   high_risk_reason_count: 2
                 ]
               ],
               candidates: [
                 thresholds: [
                   mixed_effect_count: 3,
                   branchy_function_branches: 9,
                   high_risk_direct_callers: 5
                 ],
                 limits: [
                   per_kind: 30,
                   representative_calls: 12,
                   representative_calls_per_edge: 2
                 ]
               ],
               smells: [
                 fixed_shape_map: [
                   min_keys: 4,
                   min_occurrences: 5,
                   evidence_limit: 6
                 ]
               ]
             )

    assert config.layers == [domain: "MyApp.*"]
    assert config.deps.forbidden == [{:domain, :web}]
    assert config.calls.forbidden == [{"MyApp.*", ["IO.puts"]}]
    assert config.effects.allowed == [{"MyApp.Pure.*", [:pure]}]
    assert config.boundaries.public == ["MyApp.Accounts"]
    assert config.boundaries.internal == ["MyApp.Accounts.Internal.*"]

    assert config.boundaries.internal_callers == [
             {"MyApp.Accounts.Internal.*", ["MyApp.Accounts"]}
           ]

    assert config.tests.hints == [{"lib/my_app/**", ["test/my_app"]}]
    assert config.source.forbidden_modules == ["MyApp.Legacy.*"]
    assert config.source.forbidden_files == ["lib/my_app/legacy/**"]
    assert config.risk.changed.many_direct_callers == 4
    assert config.risk.changed.wide_transitive_callers == 9
    assert config.risk.changed.branch_heavy == 7
    assert config.risk.changed.high_risk_reason_count == 2
    assert config.candidates.thresholds.mixed_effect_count == 3
    assert config.candidates.thresholds.branchy_function_branches == 9
    assert config.candidates.thresholds.high_risk_direct_callers == 5
    assert config.candidates.limits.per_kind == 30
    assert config.candidates.limits.representative_calls == 12
    assert config.candidates.limits.representative_calls_per_edge == 2
    assert config.smells.fixed_shape_map.min_keys == 4
    assert config.smells.fixed_shape_map.min_occurrences == 5
    assert config.smells.fixed_shape_map.evidence_limit == 6
  end

  test "accepts flat compatibility aliases" do
    assert %Config{} =
             config =
             Config.normalize(
               forbidden_deps: [{:domain, :web}],
               forbidden_calls: [{"MyApp.*", ["IO.puts"]}],
               allowed_effects: [{"MyApp.Pure.*", [:pure]}],
               public_api: ["MyApp.Accounts"],
               internal: ["MyApp.Accounts.Internal.*"],
               internal_callers: [{"MyApp.Accounts.Internal.*", ["MyApp.Accounts"]}],
               test_hints: [{"lib/my_app/**", ["test/my_app"]}],
               forbidden_modules: ["MyApp.Legacy.*"],
               forbidden_files: ["lib/my_app/legacy/**"]
             )

    assert config.deps.forbidden == [{:domain, :web}]
    assert config.calls.forbidden == [{"MyApp.*", ["IO.puts"]}]
    assert config.effects.allowed == [{"MyApp.Pure.*", [:pure]}]
    assert config.boundaries.public == ["MyApp.Accounts"]
    assert config.boundaries.internal == ["MyApp.Accounts.Internal.*"]

    assert config.boundaries.internal_callers == [
             {"MyApp.Accounts.Internal.*", ["MyApp.Accounts"]}
           ]

    assert config.tests.hints == [{"lib/my_app/**", ["test/my_app"]}]
    assert config.source.forbidden_modules == ["MyApp.Legacy.*"]
    assert config.source.forbidden_files == ["lib/my_app/legacy/**"]
  end

  test "reports nested config error paths" do
    assert {:error, errors} =
             Config.from_terms(
               deps: [forbidden: :bad, unexpected: []],
               risk: [changed: [branch_heavy: 0]],
               candidates: [thresholds: [mixed_effect_count: "many"]],
               smells: [fixed_shape_map: [min_keys: 0]]
             )

    violations = Enum.map(errors, &Config.Error.to_violation/1)

    assert %{key: "deps.forbidden", path: ["deps", "forbidden"]} =
             Enum.find(violations, &(&1.key == "deps.forbidden"))

    assert %{key: "deps.unexpected", path: ["deps", "unexpected"]} =
             Enum.find(violations, &(&1.key == "deps.unexpected"))

    assert %{key: "risk.changed.branch_heavy"} =
             Enum.find(violations, &(&1.key == "risk.changed.branch_heavy"))

    assert %{key: "candidates.thresholds.mixed_effect_count"} =
             Enum.find(violations, &(&1.key == "candidates.thresholds.mixed_effect_count"))

    assert %{key: "smells.fixed_shape_map.min_keys"} =
             Enum.find(violations, &(&1.key == "smells.fixed_shape_map.min_keys"))
  end
end
