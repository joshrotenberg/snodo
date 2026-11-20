defmodule Snodo.Extensions.Tasks.Postgres.StressRepo do
  @moduledoc false

  use Ecto.Repo,
    otp_app: :snodo_tasks_postgres,
    adapter: Ecto.Adapters.Postgres
end

defmodule Mix.Tasks.Tasks.Postgres.Stress do
  use Mix.Task

  alias Snodo.Extensions.Tasks.Postgres.StressRepo
  alias Snodo.Extensions.Tasks.Store.Postgres
  alias Snodo.Extensions.Tasks.Store.Postgres.Migration
  alias Snodo.Extensions.Tasks.Stress

  @shortdoc "Runs the Tasks contention and soak harness against PostgreSQL"

  @migration_version 2_026_082_502
  @default_pool_size 10
  # Ecto's migrator holds one connection for its lock and runs the migration
  # on another.
  @min_pool_size 2
  @default_store_timeout_ms 15_000
  @default_lock_timeout_ms 5_000
  @extra_switches [pool_size: :integer, store_timeout_ms: :integer, lock_timeout_ms: :integer]

  @moduledoc """
  Runs `Snodo.Extensions.Tasks.Stress` against a real PostgreSQL database.

      SNODO_TASKS_DATABASE_URL=ecto://postgres:postgres@127.0.0.1:55432/snodo_tasks \\
        mix tasks.postgres.stress --tasks 200 --writers 16 --rounds 10 --json

  The task reads `SNODO_TASKS_DATABASE_URL`, as `mix tasks.postgres.live` does,
  and fails with a configuration error without it. Each run starts its own
  Repo pool, creates and migrates a randomly named schema, runs the shared
  harness, and drops the schema. This task lives in the repository only; it is
  not in the published package. It accepts the `mix tasks.stress` switches
  (`--timeout-ms` bounds each harness wait, not the whole run; see
  `Snodo.Extensions.Tasks.Stress`) plus:

    * `--pool-size N` - Repo connections (default #{@default_pool_size}, minimum
      #{@min_pool_size}, because the migration needs two connections)
    * `--store-timeout-ms N` - store `:timeout` (default #{@default_store_timeout_ms})
    * `--lock-timeout-ms N` - store `:lock_timeout_ms` (default #{@default_lock_timeout_ms})

  The PostgreSQL store has no backpressure result, so any error, including a
  lock timeout, is reported as unexpected.
  """

  @impl Mix.Task
  def run(args) do
    case Stress.parse_args(args, @extra_switches) do
      {:ok, harness_opts, postgres_opts, json} ->
        database_url = database_url!()
        Mix.Task.run("app.start")
        harness_opts |> soak(database_url, postgres_opts) |> print_report!(json)

      {:error, :invalid_arguments} ->
        Mix.raise(
          "usage: mix tasks.postgres.stress [--tasks N] [--writers N] [--rounds N] " <>
            "[--timeout-ms N] [--pool-size N] [--store-timeout-ms N] " <>
            "[--lock-timeout-ms N] [--json]"
        )
    end
  end

  @doc """
  Prepares a unique schema in `database_url`, runs the harness, and returns its report.

  Requires the `:snodo_tasks_postgres` application's dependencies to be started.
  """
  @spec soak(keyword(), String.t(), keyword()) :: Stress.report()
  def soak(harness_opts, database_url, postgres_opts \\ []) when is_binary(database_url) do
    pool_size = at_least!(postgres_opts, :pool_size, @default_pool_size, @min_pool_size)
    store_timeout = at_least!(postgres_opts, :store_timeout_ms, @default_store_timeout_ms, 1)
    lock_timeout = at_least!(postgres_opts, :lock_timeout_ms, @default_lock_timeout_ms, 1)
    # Random lowercase base32 (a-z, 2-7), so the name needs no escaping inside
    # the quotes and concurrent Mix processes never share a schema.
    suffix = Base.encode32(:crypto.strong_rand_bytes(10), case: :lower, padding: false)
    schema = "snodo_stress_#{suffix}"

    {:ok, repo} =
      StressRepo.start_link(
        url: database_url,
        pool_size: pool_size,
        # Contended writers queue for connections by design; the default 50 ms
        # queue target would shed them. These are harness values only.
        queue_target: 500,
        queue_interval: 5_000,
        log: false
      )

    try do
      query!(~s(CREATE SCHEMA "#{schema}"))

      try do
        migrate!(schema)

        config =
          Postgres.new!(
            repo: StressRepo,
            prefix: schema,
            scope: :shared,
            timeout: store_timeout,
            lock_timeout_ms: lock_timeout,
            max_tasks: :infinity,
            max_active_tasks_per_scope: :infinity
          )

        :ok = Postgres.check_schema(config)

        Stress.run(harness_opts ++ [store: {Postgres, config}, workload: "snodo_tasks_postgres"])
      after
        query!(~s(DROP SCHEMA IF EXISTS "#{schema}" CASCADE))
      end
    after
      Supervisor.stop(repo, :normal, 5_000)
    end
  end

  defp database_url! do
    case System.get_env("SNODO_TASKS_DATABASE_URL") do
      url when is_binary(url) and url != "" ->
        url

      _missing ->
        Mix.raise(
          "SNODO_TASKS_DATABASE_URL is required for the PostgreSQL stress run; " <>
            "for example: ecto://postgres:postgres@127.0.0.1:55432/snodo_tasks"
        )
    end
  end

  defp migrate!(schema) do
    case Ecto.Migrator.up(StressRepo, @migration_version, Migration, prefix: schema, log: false) do
      :ok -> :ok
      :already_up -> :ok
    end
  end

  defp query!(sql) do
    _result = Ecto.Adapters.SQL.query!(StressRepo, sql, [])
    :ok
  end

  defp at_least!(opts, key, default, minimum) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value >= minimum ->
        value

      _invalid ->
        Mix.raise("--#{String.replace(to_string(key), "_", "-")} must be at least #{minimum}")
    end
  end

  defp print_report!(report, json) do
    if json do
      Mix.shell().info(JSON.encode!(report))
    else
      shell = Mix.shell()
      Enum.each(Stress.format_report(report), &shell.info/1)
    end

    unless report["ok"], do: Mix.raise("PostgreSQL Tasks stress invariants failed")
  end
end
