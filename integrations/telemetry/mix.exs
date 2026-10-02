defmodule Snodo.Instrumentation.Telemetry.MixProject do
  use Mix.Project

  # release-please bumps the version between these markers.
  # x-release-please-start-version
  @version "0.4.1"
  # x-release-please-end
  @source_url "https://github.com/joshrotenberg/snodo"

  def project do
    [
      app: :snodo_telemetry,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      description: "Forwards snodo instrumentation events to :telemetry",
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
          "#{@source_url}/blob/v#{@version}/integrations/telemetry/%{path}#L%{line}"
      ],
      elixirc_paths: elixirc_paths(Mix.env()),
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
    [preferred_envs: [quality: :test, "quality.types": :dev]]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      snodo_dep(:snodo, "../.."),
      # The tests run a Tasks runner through the sink.
      snodo_dep(:snodo_tasks, "../../extensions/tasks", only: :test),
      {:telemetry, "~> 1.0"},
      {:credo, "~> 1.7.19", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4.7", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false}
    ]
  end

  defp aliases do
    [
      quality: [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "credo --strict",
        "test --warnings-as-errors --raise"
      ],
      "quality.types": ["dialyzer --force-check --format short --list-unused-filters"]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  # Inside this repository the snodo packages are path dependencies. Hex does
  # not accept those, so publishing sets SNODO_HEX=1 to depend on the released
  # packages instead. All snodo packages share one version.
  defp snodo_dep(app, path, opts \\ []) do
    if System.get_env("SNODO_HEX") == "1",
      do: {app, "~> " <> @version, opts},
      else: {app, Keyword.put(opts, :path, path)}
  end
end
