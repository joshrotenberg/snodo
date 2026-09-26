defmodule SnodoConformanceFixture.MixProject do
  use Mix.Project

  # The official runner's server legs start ../fixture_server.exs from here,
  # so the core, Tasks, and the Plug adapter with Bandit share one build.
  # This project is never published.
  def project do
    [
      app: :snodo_conformance_fixture,
      version: "0.0.0",
      elixir: "~> 1.18",
      deps: [
        {:snodo, path: "../..", override: true},
        {:snodo_tasks, path: "../../extensions/tasks"},
        {:snodo_plug, path: "../../integrations/plug"},
        {:bandit, "~> 1.12.5"}
      ]
    ]
  end

  def application, do: [extra_applications: [:logger]]
end
