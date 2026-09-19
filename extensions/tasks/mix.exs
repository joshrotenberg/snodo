defmodule MCP.Extensions.Tasks.MixProject do
  use Mix.Project

  def project do
    [
      app: :mcp_ex_tasks,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      description: "Tasks extension for mcp_ex",
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
      {:mcp_ex, path: "../.."},
      {:credo, "~> 1.7.19", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4.7", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      examples: [
        "compile --warnings-as-errors",
        "mcp.example ../../examples/07_tasks_memory.exs",
        "mcp.example ../../examples/08_tasks_durable.exs",
        "mcp.example ../../examples/09_tasks_retry.exs",
        "mcp.example ../../examples/17_tasks_subscriptions.exs"
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
end
