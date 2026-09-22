defmodule MCP.Schema.Validator.JSV.MixProject do
  use Mix.Project

  def project do
    [
      app: :mcp_ex_jsv,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      description: "Optional JSON Schema validation through JSV for mcp_ex",
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
    [preferred_envs: [quality: :test, "quality.types": :dev, "example.jsv": :dev]]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:mcp_ex, path: "../.."},
      {:jsv, "~> 0.22.0"},
      {:credo, "~> 1.7.19", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4.7", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      "example.jsv": [
        "compile --warnings-as-errors",
        "mcp.example ../../examples/22_full_schema_validation.exs"
      ],
      quality: [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "credo --strict",
        "test --warnings-as-errors --raise",
        "example.jsv"
      ],
      "quality.types": ["dialyzer --force-check --format short --list-unused-filters"]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]
end
