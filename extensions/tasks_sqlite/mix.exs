defmodule Snodo.Extensions.Tasks.SQLite.MixProject do
  use Mix.Project

  def project do
    [
      app: :snodo_tasks_sqlite,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      description: "SQLite persistence adapter for snodo Tasks",
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
        "example.sqlite": :dev,
        quality: :test,
        "quality.types": :dev,
        "tasks.sqlite.contract": :test
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
      {:ecto_sqlite3, "~> 0.24.1", optional: true},
      {:credo, "~> 1.7.19", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4.7", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      "example.sqlite": [
        "compile --warnings-as-errors",
        "snodo.example ../../examples/11_tasks_sqlite.exs"
      ],
      quality: [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "credo --strict",
        "test --warnings-as-errors --raise",
        "tasks.sqlite.contract",
        "example.sqlite"
      ],
      "quality.types": ["dialyzer --force-check --format short --list-unused-filters"]
    ]
  end
end
