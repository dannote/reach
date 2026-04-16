defmodule Reach.MixProject do
  use Mix.Project

  @version "1.1.2"
  @source_url "https://github.com/dannote/reach"

  def project do
    [
      app: :reach,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      dialyzer: [
        plt_file: {:no_warn, "_build/dev/dialyxir_plt.plt"},
        plt_add_apps: [:mix, :eex]
      ],
      name: "Reach",
      description: "Program dependence graph for Elixir and Erlang",
      source_url: @source_url,
      docs: docs(),
      package: package()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  def cli do
    [preferred_envs: [ci: :test]]
  end

  defp aliases do
    [
      ci: [
        "compile --warnings-as-errors",
        "format --check-formatted",
        "js.check",
        "credo --strict",
        "dialyzer",
        "test"
      ],
      "assets.build": [
        "volt.build --entry assets/js/app.ts --outdir priv/static --no-hash --name reach"
      ]
    ]
  end

  defp deps do
    [
      {:libgraph, "~> 0.16.0"},
      {:stream_data, "~> 1.0", only: [:test, :dev]},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:jason, "~> 1.0", optional: true},
      {:makeup, "~> 1.0", optional: true},
      {:makeup_elixir, "~> 1.0", optional: true},
      {:volt, "~> 0.4", only: :dev, runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp docs do
    [
      main: "Reach",
      extras: [
        "README.md",
        "CHANGELOG.md",
        "LICENSE"
      ],
      groups_for_modules: [
        "Public API": [Reach, Reach.Project],
        IR: [Reach.IR, Reach.IR.Node],
        Analysis: [Reach.Effects],
        Frontends: [Reach.Frontend.Elixir, Reach.Frontend.Erlang]
      ],
      source_url: @source_url,
      source_ref: "master"
    ]
  end

  def build_assets(_) do
    {:ok, _result} =
      Volt.Builder.build(
        entry: "assets/js/app.ts",
        outdir: "priv/static",
        hash: false,
        name: "reach",
        sourcemap: false,
        code_splitting: false,
        define: %{"process.env.NODE_ENV" => ~s("production")},
        aliases: %{"@reach" => "assets/js"},
        node_modules: Path.expand("assets/node_modules")
      )
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib priv mix.exs README.md CHANGELOG.md LICENSE .formatter.exs)
    ]
  end
end
