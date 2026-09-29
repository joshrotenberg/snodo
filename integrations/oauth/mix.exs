defmodule Snodo.OAuth.MixProject do
  use Mix.Project

  # release-please bumps the version between these markers.
  # x-release-please-start-version
  @version "0.3.1"
  # x-release-please-end
  @source_url "https://github.com/joshrotenberg/snodo"

  def project do
    [
      app: :snodo_oauth,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      description: "OAuth 2.1 resource server plugs for snodo MCP servers",
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
        source_url_pattern: "#{@source_url}/blob/v#{@version}/integrations/oauth/%{path}#L%{line}"
      ],
      elixirc_paths: elixirc_paths(Mix.env()),
      dialyzer: [
        plt_add_apps: [:inets, :mix],
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

  # :inets supplies the JWKS fetcher's HTTP client; :ssl and :public_key
  # supply peer verification for it.
  def application do
    [extra_applications: [:inets, :logger, :public_key, :ssl]]
  end

  defp deps do
    [
      snodo_dep(:snodo, "../.."),
      {:plug, "~> 1.20"},
      {:jose, "~> 1.11"},
      # The integration tests drive Snodo.Transport.Plug on a real Bandit
      # listener. Neither is needed at runtime.
      {:snodo_plug, path: "../plug", only: [:dev, :test]},
      {:bandit, "~> 1.12.5", only: [:dev, :test]},
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
  defp snodo_dep(app, path) do
    if System.get_env("SNODO_HEX") == "1",
      do: {app, "~> " <> @version},
      else: {app, path: path}
  end
end
