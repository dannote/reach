defmodule Reach.Check.Architecture.ConfigTest do
  use ExUnit.Case, async: true

  alias Reach.Check.Architecture.Config

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
               tests: [hints: [{"lib/my_app/**", ["test/my_app"]}]]
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
               test_hints: [{"lib/my_app/**", ["test/my_app"]}]
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
  end

  test "reports nested config error paths" do
    assert {:error, errors} = Config.from_terms(deps: [forbidden: :bad, unexpected: []])

    violations = Enum.map(errors, &Config.Error.to_violation/1)

    assert %{key: "deps.forbidden", path: ["deps", "forbidden"]} =
             Enum.find(violations, &(&1.key == "deps.forbidden"))

    assert %{key: "deps.unexpected", path: ["deps", "unexpected"]} =
             Enum.find(violations, &(&1.key == "deps.unexpected"))
  end
end
