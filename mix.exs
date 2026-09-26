defmodule Snodo.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/joshrotenberg/snodo"

  def project do
    [
      app: :snodo,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      description: "Model Context Protocol servers and clients for Elixir",
      source_url: @source_url,
      package: package(),
      docs: docs(),
      elixirc_paths: elixirc_paths(Mix.env()),
      # Scripts under test/fixtures are run as subprocesses, not loaded as tests.
      test_ignore_filters: [~r{^test/fixtures/}],
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
        "snodo.contract": :test
      ]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:crypto, :inets, :logger, :public_key, :ssl],
      mod: {Snodo.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:credo, "~> 1.7.19", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4.7", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url, "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md"},
      # lib/mix holds tasks that run this repository's examples and compliance
      # vectors; they are not useful without the checkout.
      files: ~w(lib/snodo lib/snodo.ex mix.exs README.md CHANGELOG.md LICENSE .formatter.exs)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      extras: [
        "README.md",
        "guides/getting-started.md",
        "guides/components.md",
        "guides/client.md",
        "guides/transports.md",
        "guides/application-stack.md",
        "guides/interactive-operations.md",
        "guides/subscriptions.md",
        "guides/authorization.md",
        "guides/extensions.md",
        "guides/instrumentation.md",
        "guides/initialize-era-clients.md",
        "guides/compatibility.md",
        "guides/protocol-compliance.md",
        "CHANGELOG.md"
      ],
      groups_for_extras: [Guides: ~r{^guides/}],
      groups_for_modules: [
        Server: [
          ~r/^Snodo\.Server/,
          ~r/^Snodo\.(Tool|Resource|Prompt|Completion|Result|Error|Context)/
        ],
        Client: [~r/^Snodo\.Client/],
        Transports: [~r/^Snodo\.Transport/],
        Protocol: [~r/^Snodo\.(Protocol|Envelope|Compliance)/]
      ]
    ]
  end

  defp aliases do
    [
      quality: [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "credo --strict",
        "test --warnings-as-errors --raise",
        "snodo.contract",
        "examples",
        "cmd --cd extensions/tasks mix quality",
        "cmd --cd extensions/tasks_postgres mix quality",
        "cmd --cd extensions/tasks_sqlite mix quality",
        "cmd --cd integrations/plug mix quality",
        "cmd --cd integrations/schema_jsv mix quality"
      ],
      "quality.types": [
        "dialyzer --format short --list-unused-filters",
        "cmd --cd extensions/tasks mix quality.types",
        "cmd --cd extensions/tasks_postgres mix quality.types",
        "cmd --cd extensions/tasks_sqlite mix quality.types",
        "cmd --cd integrations/plug mix quality.types",
        "cmd --cd integrations/schema_jsv mix quality.types"
      ]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]
end
