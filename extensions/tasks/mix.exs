defmodule Snodo.Extensions.Tasks.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/joshrotenberg/snodo"

  def project do
    [
      app: :snodo_tasks,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      description: "The MCP Tasks extension for snodo",
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
        source_url_pattern: "#{@source_url}/blob/v#{@version}/extensions/tasks/%{path}#L%{line}"
      ],
      elixirc_paths: elixirc_paths(Mix.env()),
      dialyzer: [
        # :ex_unit so the PLT knows ExUnit.AssertionError, which test/support raises.
        plt_add_apps: [:mix, :ex_unit],
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
        "tasks.contract": :test
      ]
    ]
  end

  def application do
    [extra_applications: [:crypto]]
  end

  defp deps do
    [
      snodo_dep(:snodo, "../.."),
      {:credo, "~> 1.7.19", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4.7", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false}
    ]
  end

  defp aliases do
    [
      examples: [
        "compile --warnings-as-errors",
        "snodo.example ../../examples/07_tasks_memory.exs",
        "snodo.example ../../examples/08_tasks_durable.exs",
        "snodo.example ../../examples/09_tasks_retry.exs",
        "snodo.example ../../examples/17_tasks_subscriptions.exs"
      ],
      quality: [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "credo --strict",
        "test --warnings-as-errors --raise",
        "tasks.contract",
        "examples"
      ],
      "quality.types": ["dialyzer --force-check --format short --list-unused-filters"]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  # Inside this repository the snodo packages are path dependencies. Hex does
  # not accept those, so publishing sets SNODO_HEX=1 to depend on the released
  # packages instead. All snodo packages share one version.
  defp snodo_dep(app, path) do
    if System.get_env("SNODO_HEX") == "1",
      do: {app, "~> " <> @version},
      else: {app, path: path}
  end
end
