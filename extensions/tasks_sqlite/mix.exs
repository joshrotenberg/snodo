defmodule Snodo.Extensions.Tasks.SQLite.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/joshrotenberg/snodo"

  def project do
    [
      app: :snodo_tasks_sqlite,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      description: "SQLite store for snodo Tasks",
      source_url: @source_url,
      package: [
        licenses: ["MIT"],
        links: %{"GitHub" => @source_url, "Changelog" => @source_url <> "/blob/main/CHANGELOG.md"},
        files: ~w(lib mix.exs README.md LICENSE .formatter.exs)
      ],
      docs: [
        main: "readme",
        extras: ["README.md"],
        source_ref: "v#{@version}",
        source_url_pattern:
          "#{@source_url}/blob/v#{@version}/extensions/tasks_sqlite/%{path}#L%{line}"
      ],
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
      snodo_dep(:snodo_tasks, "../tasks"),
      {:ecto_sql, "~> 3.14"},
      {:jason, "~> 1.4"},
      {:ecto_sqlite3, "~> 0.24.1", optional: true},
      {:credo, "~> 1.7.19", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4.7", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false}
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

  # Inside this repository the snodo packages are path dependencies. Hex does
  # not accept those, so publishing sets SNODO_HEX=1 to depend on the released
  # packages instead. All snodo packages share one version.
  defp snodo_dep(app, path) do
    if System.get_env("SNODO_HEX") == "1",
      do: {app, "~> " <> @version},
      else: {app, path: path}
  end
end
