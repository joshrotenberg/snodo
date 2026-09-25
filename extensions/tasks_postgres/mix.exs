defmodule Snodo.Extensions.Tasks.Postgres.MixProject do
  use Mix.Project

  def project do
    [
      app: :snodo_tasks_postgres,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      description: "PostgreSQL persistence adapter for snodo Tasks",
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
        "example.postgres": :dev,
        quality: :test,
        "quality.postgres": :test,
        "quality.types": :dev,
        "tasks.postgres.contract": :test,
        "tasks.postgres.live": :test
      ]
    ]
  end

  def application do
    [extra_applications: [:crypto, :logger]]
  end

  defp deps do
    [
      {:snodo_tasks, path: "../tasks"},
      {:ecto_sql, "~> 3.14"},
      {:jason, "~> 1.4"},
      {:postgrex, "~> 0.22.4", optional: true},
      {:credo, "~> 1.7.19", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4.7", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      "example.postgres": [
        "compile --warnings-as-errors",
        "snodo.example ../../examples/10_tasks_postgres.exs"
      ],
      quality: [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "credo --strict",
        "test --warnings-as-errors --raise",
        "tasks.postgres.contract"
      ],
      "quality.postgres": [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "tasks.postgres.live",
        "example.postgres"
      ],
      "quality.types": ["dialyzer --force-check --format short --list-unused-filters"]
    ]
  end
end
