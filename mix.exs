defmodule Reach.MixProject do
  use Mix.Project

  @version "0.1.0"
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
        plt_add_apps: [:mix]
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
        "credo --strict",
        "dialyzer",
        "test"
      ]
    ]
  end

  defp deps do
    [
      {:libgraph, "~> 0.16.0"},
      {:stream_data, "~> 1.0", only: [:test, :dev]},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp docs do
    [
      main: "Reach",
      extras: [
        "README.md",
        "LICENSE"
      ],
      groups_for_modules: [
        "Public API": [Reach],
        IR: [Reach.IR, Reach.IR.Node],
        Analysis: [Reach.Effects, Reach.Query],
        Frontends: [Reach.Frontend.Elixir, Reach.Frontend.Erlang, Reach.Frontend.BEAM]
      ],
      source_url: @source_url,
      source_ref: "master"
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib mix.exs README.md LICENSE .formatter.exs)
    ]
  end
end
