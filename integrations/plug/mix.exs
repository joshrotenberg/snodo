defmodule Snodo.Transport.Plug.MixProject do
  use Mix.Project

  def project do
    [
      app: :snodo_plug,
      version: "0.1.0",
      elixir: "~> 1.18",
      description: "Plug and Bandit transport for snodo MCP servers",
      source_url: "https://github.com/joshrotenberg/snodo",
      package: [
        licenses: ["MIT"],
        links: %{"GitHub" => "https://github.com/joshrotenberg/snodo"},
        files: ~w(lib mix.exs README.md LICENSE .formatter.exs)
      ],
      elixirc_paths: if(Mix.env() == :test, do: ["lib", "test/support"], else: ["lib"]),
      dialyzer: [plt_local_path: "priv/plts", flags: [:unmatched_returns, :error_handling]],
      aliases: [
        quality: [
          "format --check-formatted",
          "compile --warnings-as-errors",
          "credo --strict",
          "test --warnings-as-errors --raise",
          "example.plug"
        ],
        "example.plug": ["run ../../examples/21_plug_bandit.exs --check"],
        "quality.types": ["dialyzer --force-check --format short --list-unused-filters"]
      ],
      deps: [
        {:snodo, path: "../.."},
        {:plug, "~> 1.20.3"},
        {:bandit, "~> 1.12.5", only: [:dev, :test]},
        {:credo, "~> 1.7.19", only: [:dev, :test], runtime: false},
        {:dialyxir, "~> 1.4.7", only: [:dev, :test], runtime: false}
      ]
    ]
  end

  def application, do: [extra_applications: [:logger]]
  def cli, do: [preferred_envs: [quality: :test, "quality.types": :dev, "example.plug": :dev]]
end
