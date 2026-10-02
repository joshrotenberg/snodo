defmodule Snodo.Proxy.MixProject do
  use Mix.Project

  # x-release-please-start-version
  @version "0.4.0"
  # x-release-please-end
  @source_url "https://github.com/joshrotenberg/snodo"

  def project do
    [
      app: :snodo_proxy,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      description: "Aggregating proxy for MCP backends",
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
        source_url_pattern: "#{@source_url}/blob/v#{@version}/integrations/proxy/%{path}#L%{line}"
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

  def cli, do: [preferred_envs: [quality: :test, "quality.types": :dev]]

  def application do
    [extra_applications: [:logger], mod: {Snodo.Proxy.Application, []}]
  end

  defp deps do
    [
      snodo_dep(),
      {:credo, "~> 1.7.19", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4.7", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false}
    ]
  end

  defp snodo_dep do
    if System.get_env("SNODO_HEX") == "1",
      do: {:snodo, "~> " <> @version},
      else: {:snodo, path: "../.."}
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
end
