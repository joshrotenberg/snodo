defmodule Snodo.MixProject do
  use Mix.Project

  def project do
    [
      app: :snodo,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      description: "A router-first Model Context Protocol architecture spike",
      elixirc_paths: elixirc_paths(Mix.env()),
      # Scripts under test/fixtures are run as subprocesses, not loaded as tests.
      test_ignore_filters: [~r{^test/fixtures/}],
      dialyzer: [
        plt_add_apps: [:mix],
        plt_local_path: "priv/plts",
        flags: [:unmatched_returns, :error_handling]
      ],
      aliases: aliases(),
      deps: deps()
    ]
  end

  def cli do
    [
      preferred_envs: [
        examples: :dev,
        quality: :test,
        "quality.types": :dev,
        "snodo.contract": :test
      ]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:crypto, :inets, :logger, :public_key, :ssl],
      mod: {Snodo.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:credo, "~> 1.7.19", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4.7", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      quality: [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "credo --strict",
        "test --warnings-as-errors --raise",
        "snodo.contract",
        "examples",
        "cmd --cd extensions/tasks mix quality",
        "cmd --cd extensions/tasks_postgres mix quality",
        "cmd --cd extensions/tasks_sqlite mix quality",
        "cmd --cd integrations/plug mix quality",
        "cmd --cd integrations/schema_jsv mix quality"
      ],
      "quality.types": [
        "dialyzer --format short --list-unused-filters",
        "cmd --cd extensions/tasks mix quality.types",
        "cmd --cd extensions/tasks_postgres mix quality.types",
        "cmd --cd extensions/tasks_sqlite mix quality.types",
        "cmd --cd integrations/plug mix quality.types",
        "cmd --cd integrations/schema_jsv mix quality.types"
      ]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]
end
