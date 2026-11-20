defmodule ReleaseSmoke.MixProject do
  use Mix.Project

  def project do
    [
      app: :release_smoke,
      version: "0.0.0",
      deps: deps(System.fetch_env!("SNODO_SMOKE_VERSION"))
    ]
  end

  defp deps(version) do
    [
      # Published archives name hexpm for these transitive dependencies.
      # The smoke script checks the original requirements in the Hex lock.
      {:snodo, version, repo: "local", override: true},
      {:snodo_tasks, version, repo: "local", override: true},
      {:snodo_plug, version, repo: "local"},
      {:snodo_jsv, version, repo: "local"},
      {:snodo_oauth, version, repo: "local"},
      {:snodo_telemetry, version, repo: "local"},
      {:snodo_proxy, version, repo: "local"},
      {:snodo_otp, version, repo: "local"},
      {:snodo_tasks_postgres, version, repo: "local", runtime: false},
      {:snodo_tasks_sqlite, version, repo: "local", runtime: false},
      {:postgrex, "~> 0.22", runtime: false},
      {:ecto_sqlite3, "~> 0.24", runtime: false}
    ]
  end
end
