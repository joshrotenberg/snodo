defmodule Snodo.Extensions.Tasks.Postgres.StressTest do
  # Reads and temporarily clears SNODO_TASKS_DATABASE_URL, which is global.
  use ExUnit.Case, async: false

  alias Mix.Tasks.Tasks.Postgres.Stress, as: StressTask

  @url_variable "SNODO_TASKS_DATABASE_URL"

  test "the Mix task requires the database URL" do
    previous = System.get_env(@url_variable)
    System.delete_env(@url_variable)
    on_exit(fn -> if previous, do: System.put_env(@url_variable, previous) end)

    assert_raise Mix.Error, ~r/SNODO_TASKS_DATABASE_URL is required/, fn ->
      StressTask.run(~w(--tasks 1))
    end
  end

  test "the Mix task rejects unknown switches" do
    assert_raise Mix.Error, ~r/usage: mix tasks.postgres.stress/, fn ->
      StressTask.run(~w(--unknown 1))
    end
  end

  test "the soak rejects a pool too small for the migration before connecting" do
    assert_raise Mix.Error, ~r/--pool-size must be at least 2/, fn ->
      StressTask.soak([tasks: 1], "ecto://unused:unused@127.0.0.1:1/unused", pool_size: 1)
    end
  end

  @tag :postgres_live
  @tag timeout: 120_000
  test "the shared soak harness passes against a live PostgreSQL store" do
    database_url = System.fetch_env!(@url_variable)

    report =
      StressTask.soak([tasks: 4, writers: 4, rounds: 2, timeout_ms: 30_000], database_url,
        pool_size: 6
      )

    assert report["ok"], inspect(report, pretty: true)
    assert report["workload"] == "snodo_tasks_postgres"
    assert report["store"] == "Snodo.Extensions.Tasks.Store.Postgres"

    assert %{"applied" => 4, "attempts" => 16, "committedEvents" => 4, "unexpected" => 0} =
             report["scenarios"]["casContention"]

    assert %{
             "staleTransitionsRejected" => 4,
             "staleRenewalsRejected" => 4,
             "liveTransitionsApplied" => 4,
             "untouchedAfterStale" => 4,
             "verifiedTasks" => 4,
             "committedEvents" => 4
           } = report["scenarios"]["leaseFencing"]

    assert %{"verifiedTasks" => 4} = report["scenarios"]["casContention"]

    assert %{"completed" => 8, "expectedJobs" => 8, "finalJobs" => 0, "releaseFailures" => 0} =
             report["scenarios"]["runnerSoak"]
  end
end
