defmodule Snodo.Extensions.Tasks.SQLite.StressTest do
  # The soak starts a named Repo and owns a temporary database file.
  use ExUnit.Case, async: false

  alias Mix.Tasks.Tasks.Sqlite.Stress, as: StressTask

  test "the shared soak harness passes against a file-backed SQLite store" do
    report = StressTask.soak(tasks: 4, writers: 4, rounds: 2, timeout_ms: 30_000)

    assert report["ok"], inspect(report, pretty: true)
    assert report["workload"] == "snodo_tasks_sqlite"
    assert report["store"] == "Snodo.Extensions.Tasks.Store.SQLite"

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

  test "the Mix task prints a report and removes its database directory" do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
    before = stress_directories()

    StressTask.run(~w(--tasks 2 --writers 3 --rounds 1 --pool-size 3 --json))

    assert_receive {:mix_shell, :info, [json]}
    assert %{"ok" => true, "workload" => "snodo_tasks_sqlite"} = JSON.decode!(json)
    assert stress_directories() -- before == []
  end

  test "the Mix task rejects unknown switches and non-positive pool sizes" do
    assert_raise Mix.Error, ~r/usage: mix tasks.sqlite.stress/, fn ->
      StressTask.run(~w(--unknown 1))
    end

    assert_raise Mix.Error, ~r/--pool-size must be positive/, fn ->
      StressTask.soak([tasks: 1], pool_size: 0)
    end
  end

  defp stress_directories do
    Path.wildcard(Path.join(System.tmp_dir!(), "snodo_tasks_sqlite_stress_*"))
  end
end
