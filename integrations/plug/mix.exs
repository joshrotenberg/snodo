defmodule Snodo.Transport.Plug.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/joshrotenberg/snodo"

  def project do
    [
      app: :snodo_plug,
      version: @version,
      elixir: "~> 1.18",
      description: "Plug and Bandit transport for snodo MCP servers",
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
        source_url_pattern: "#{@source_url}/blob/v#{@version}/integrations/plug/%{path}#L%{line}"
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
        snodo_dep(:snodo, "../.."),
        {:plug, "~> 1.20.3"},
        {:bandit, "~> 1.12.5", only: [:dev, :test]},
        {:credo, "~> 1.7.19", only: [:dev, :test], runtime: false},
        {:dialyxir, "~> 1.4.7", only: [:dev, :test], runtime: false},
        {:ex_doc, "~> 0.40", only: :dev, runtime: false}
      ]
    ]
  end

  def application, do: [extra_applications: [:logger]]
  def cli, do: [preferred_envs: [quality: :test, "quality.types": :dev, "example.plug": :dev]]

  # Inside this repository the snodo packages are path dependencies. Hex does
  # not accept those, so publishing sets SNODO_HEX=1 to depend on the released
  # packages instead. All snodo packages share one version.
  defp snodo_dep(app, path) do
    if System.get_env("SNODO_HEX") == "1",
      do: {app, "~> " <> @version},
      else: {app, path: path}
  end
end
