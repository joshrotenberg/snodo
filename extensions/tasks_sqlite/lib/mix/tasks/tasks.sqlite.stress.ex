defmodule Snodo.Extensions.Tasks.SQLite.StressRepo do
  @moduledoc false

  use Ecto.Repo,
    otp_app: :snodo_tasks_sqlite,
    adapter: Ecto.Adapters.SQLite3
end

defmodule Mix.Tasks.Tasks.Sqlite.Stress do
  use Mix.Task

  alias Snodo.Extensions.Tasks.SQLite.StressRepo
  alias Snodo.Extensions.Tasks.Store.SQLite
  alias Snodo.Extensions.Tasks.Store.SQLite.Migration
  alias Snodo.Extensions.Tasks.Stress

  @shortdoc "Runs the Tasks contention and soak harness against SQLite"

  @migration_version 2_026_082_602
  @default_pool_size 5
  @default_busy_timeout_ms 5_000
  @default_store_timeout_ms 15_000
  @extra_switches [pool_size: :integer, busy_timeout_ms: :integer, store_timeout_ms: :integer]

  @moduledoc """
  Runs `Snodo.Extensions.Tasks.Stress` against a file-backed SQLite store.

      mix tasks.sqlite.stress
      mix tasks.sqlite.stress --tasks 200 --writers 16 --rounds 10 --json

  Each run creates a WAL database in a new, randomly named temporary
  directory, migrates it, starts a pooled Repo, runs the shared harness, and
  deletes the directory. This task lives in the repository only; it is not in
  the published package. It accepts the `mix tasks.stress` switches
  (`--timeout-ms` bounds each harness wait, not the whole run; see
  `Snodo.Extensions.Tasks.Stress`) plus:

    * `--pool-size N` - Repo connections (default #{@default_pool_size})
    * `--busy-timeout-ms N` - SQLite busy timeout (default #{@default_busy_timeout_ms})
    * `--store-timeout-ms N` - store `:timeout` (default #{@default_store_timeout_ms})

  `{:error, :database_busy}` is the store's documented backpressure result, so
  the report counts it as `busy` rather than as an unexpected error. The
  harness still checks each Task's ledger and snapshot, so a busy result that
  hid a commit fails the run.
  """

  @impl Mix.Task
  def run(args) do
    case Stress.parse_args(args, @extra_switches) do
      {:ok, harness_opts, sqlite_opts, json} ->
        Mix.Task.run("app.start")
        harness_opts |> soak(sqlite_opts) |> print_report!(json)

      {:error, :invalid_arguments} ->
        Mix.raise(
          "usage: mix tasks.sqlite.stress [--tasks N] [--writers N] [--rounds N] " <>
            "[--timeout-ms N] [--pool-size N] [--busy-timeout-ms N] " <>
            "[--store-timeout-ms N] [--json]"
        )
    end
  end

  @doc """
  Prepares a temporary SQLite database, runs the harness, and returns its report.

  Requires the `:snodo_tasks_sqlite` application to be running.
  """
  @spec soak(keyword(), keyword()) :: Stress.report()
  def soak(harness_opts, sqlite_opts \\ []) do
    pool_size = positive!(sqlite_opts, :pool_size, @default_pool_size)
    busy_timeout = positive!(sqlite_opts, :busy_timeout_ms, @default_busy_timeout_ms)
    store_timeout = positive!(sqlite_opts, :store_timeout_ms, @default_store_timeout_ms)

    directory = create_directory!()
    database = Path.join(directory, "tasks.sqlite3")

    try do
      {:ok, repo} = start_repo(database, pool_size, busy_timeout)

      try do
        migrate!()

        config =
          SQLite.new!(
            repo: StressRepo,
            scope: :shared,
            timeout: store_timeout,
            max_tasks: :infinity,
            max_active_tasks_per_scope: :infinity
          )

        :ok = SQLite.check_schema(config)

        Stress.run(
          harness_opts ++
            [
              store: {SQLite, config},
              workload: "snodo_tasks_sqlite",
              busy?: &(&1 == {:error, :database_busy})
            ]
        )
      after
        Supervisor.stop(repo, :normal, 5_000)
      end
    after
      File.rm_rf!(directory)
    end
  end

  # A random name created with a non-recursive mkdir, so two Mix processes
  # can never share a database: an existing directory is an error, not reuse.
  defp create_directory! do
    suffix = Base.encode32(:crypto.strong_rand_bytes(10), case: :lower, padding: false)
    directory = Path.join(System.tmp_dir!(), "snodo_tasks_sqlite_stress_#{suffix}")

    case File.mkdir(directory) do
      :ok -> directory
      {:error, reason} -> Mix.raise("could not create #{directory}: #{inspect(reason)}")
    end
  end

  defp start_repo(database, pool_size, busy_timeout) do
    Application.put_env(:snodo_tasks_sqlite, StressRepo, busy_timeout: busy_timeout)

    StressRepo.start_link(
      database: database,
      pool_size: pool_size,
      journal_mode: :wal,
      foreign_keys: :on,
      busy_timeout: busy_timeout,
      default_transaction_mode: :deferred,
      # Contended writers wait for a connection and then for the write slot,
      # so DBConnection's default 50 ms queue target would shed them. These are
      # harness values for deliberate contention, not production guidance.
      queue_target: 500,
      queue_interval: 5_000,
      log: false
    )
  end

  defp migrate! do
    case Ecto.Migrator.up(StressRepo, @migration_version, Migration, log: false) do
      :ok -> :ok
      :already_up -> :ok
    end
  end

  defp positive!(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 -> value
      _invalid -> Mix.raise("--#{String.replace(to_string(key), "_", "-")} must be positive")
    end
  end

  defp print_report!(report, json) do
    if json do
      Mix.shell().info(JSON.encode!(report))
    else
      shell = Mix.shell()
      Enum.each(Stress.format_report(report), &shell.info/1)
    end

    unless report["ok"], do: Mix.raise("SQLite Tasks stress invariants failed")
  end
end
