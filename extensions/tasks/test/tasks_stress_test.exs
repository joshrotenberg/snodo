defmodule Snodo.TasksStressTest.FaultyStore do
  @moduledoc false

  # Delegates to Store.Memory and injects SQLite's backpressure result in one
  # of three modes:
  #
  #   * :transient - every other create, claim, and renewal, and every CAS
  #     attempt by writer 1, returns busy without touching the store, as a
  #     correct store does.
  #   * :mutating_cas - writer 1's CAS attempt commits, then reports busy.
  #   * :mutating_renew - a renewal of a stale fencing lease first releases
  #     the live claim, then reports busy. Retries reach Memory, which refuses
  #     the stale lease, so only a state check can catch it.

  alias Snodo.Extensions.Tasks.Store.Memory

  @busy {:error, :database_busy}

  def new(memory, mode) do
    table = :ets.new(__MODULE__, [:public, :set])
    :ets.insert(table, {:calls, 0})
    {__MODULE__, {memory, mode, table}}
  end

  def authorize({memory, _mode, _table}, context, action),
    do: Memory.authorize(memory, context, action)

  def create({memory, mode, table}, task, work, access),
    do: transient(mode, table, fn -> Memory.create(memory, task, work, access) end)

  def get({memory, _mode, _table}, task_id, access), do: Memory.get(memory, task_id, access)

  def worker_snapshot({memory, _mode, _table}, task_id, lease),
    do: Memory.worker_snapshot(memory, task_id, lease)

  def claim({memory, mode, table}, task_id, owner_id, lease_ms) do
    transient(mode, table, fn ->
      result = Memory.claim(memory, task_id, owner_id, lease_ms)
      with {:ok, _snapshot, lease} <- result, do: :ets.insert(table, {{:lease, task_id}, lease})
      result
    end)
  end

  def claim_next({memory, _mode, _table}, owner_id, lease_ms),
    do: Memory.claim_next(memory, owner_id, lease_ms)

  def renew({memory, :mutating_renew, table}, lease, lease_ms) do
    with %{task_id: task_id} <- lease,
         true <- String.contains?(task_id, "-fence-"),
         [{_key, live}] when live != lease <- :ets.lookup(table, {:lease, task_id}),
         true <- :ets.insert_new(table, {{:mutated, task_id}, true}) do
      :ok = Memory.release(memory, live)
      @busy
    else
      _other -> Memory.renew(memory, lease, lease_ms)
    end
  end

  def renew({memory, mode, table}, lease, lease_ms),
    do: transient(mode, table, fn -> Memory.renew(memory, lease, lease_ms) end)

  def release({memory, _mode, _table}, lease), do: Memory.release(memory, lease)
  def reap({memory, _mode, _table}), do: Memory.reap(memory)

  def transition({memory, mode, _table}, task_id, revision, event, authority) do
    commit = fn -> Memory.transition(memory, task_id, revision, event, authority) end

    cas_writer_one? =
      String.contains?(task_id, "-cas-") and String.ends_with?(event.id, "-writer-1")

    case {mode, cas_writer_one?} do
      {:transient, true} ->
        @busy

      {:mutating_cas, true} ->
        _result = commit.()
        @busy

      _other ->
        commit.()
    end
  end

  def history({memory, _mode, _table}, task_id, access),
    do: Memory.history(memory, task_id, access)

  defp transient(:transient, table, fun) do
    if rem(:ets.update_counter(table, :calls, 1), 2) == 1, do: @busy, else: fun.()
  end

  defp transient(_mode, _table, fun), do: fun.()
end

defmodule Snodo.TasksStressTest do
  use ExUnit.Case, async: false

  @moduletag :tasks_package

  alias Snodo.Extensions.Tasks.Store.Memory
  alias Snodo.Extensions.Tasks.Stress
  alias Snodo.TasksStressTest.FaultyStore

  test "contention, fencing, and runner soak produce exact invariant evidence" do
    report = Stress.run(tasks: 4, writers: 5, rounds: 3, timeout_ms: 5_000)

    assert report["ok"], inspect(report, pretty: true)
    assert report["schemaVersion"] == 2
    assert report["workload"] == "snodo_tasks_memory"
    assert report["store"] == "Snodo.Extensions.Tasks.Store.Memory"
    assert report["busyRetries"] == 0
    assert Enum.all?(report["invariants"], fn {_name, passed?} -> passed? end)
    assert map_size(report["invariants"]) == 11

    assert %{
             "applied" => 4,
             "attempts" => 20,
             "busy" => 0,
             "committedEvents" => 4,
             "conflicts" => 16,
             "terminalTasks" => 4,
             "winnerTasks" => 4,
             "ledgerTasks" => 4,
             "verifiedTasks" => 4,
             "mismatchSamples" => [],
             "unexpected" => 0,
             "unexpectedSamples" => []
           } = report["scenarios"]["casContention"]

    assert %{"p50" => p50, "p95" => p95, "p99" => p99, "max" => max} =
             report["scenarios"]["casContention"]["latencyUs"]

    assert p50 <= p95 and p95 <= p99 and p99 <= max

    assert %{
             "tasks" => 4,
             "staleTransitionsRejected" => 4,
             "staleRenewalsRejected" => 4,
             "untouchedAfterStale" => 4,
             "liveTransitionsApplied" => 4,
             "ledgerTasks" => 4,
             "verifiedTasks" => 4,
             "unexpected" => 0,
             "committedEvents" => 4,
             "terminalTasks" => 4
           } = report["scenarios"]["leaseFencing"]

    runner = report["scenarios"]["runnerSoak"]
    assert runner["expectedJobs"] == 12
    assert runner["started"] == 12
    assert runner["stopped"] == 12
    assert runner["completed"] == 12
    assert runner["peakJobs"] == 4
    assert runner["finalJobs"] == 0
    assert runner["releaseFailures"] == 0
    assert runner["appliedTransitions"] == 12
    assert runner["otherTransitions"] == 0
    assert runner["durationUs"] > 0
    assert runner["observedJobDurationUs"] > 0
    assert runner["jobsPerSecond"] > 0

    assert JSON.encode!(report)
  end

  test "a caller-owned store is used as given and can be reused across runs" do
    store = start_memory!()

    opts = [
      store: {Memory, store},
      workload: "caller_memory",
      busy?: &busy?/1,
      tasks: 2,
      writers: 3,
      rounds: 1,
      timeout_ms: 5_000
    ]

    assert %{"ok" => true, "workload" => "caller_memory"} = Stress.run(opts)
    assert %{"ok" => true} = Stress.run(opts)
    assert Process.alive?(store)
  end

  test "busy results that leave state alone are retried in setup and lost in the CAS race" do
    report =
      Stress.run(
        store: FaultyStore.new(start_memory!(), :transient),
        busy?: &busy?/1,
        tasks: 3,
        writers: 3,
        rounds: 1,
        timeout_ms: 5_000
      )

    assert report["ok"], inspect(report, pretty: true)
    assert report["busyRetries"] > 0
    # Writer 1 is refused on every contended Task and never counts as a winner.
    assert %{"busy" => 3, "applied" => 3, "conflicts" => 3, "verifiedTasks" => 3} =
             report["scenarios"]["casContention"]
  end

  test "a CAS attempt that commits and then reports busy fails the run" do
    # One writer per Task: its commit is the only one, so no writer reports
    # applied while the ledger and snapshot hold its event.
    report =
      Stress.run(
        store: FaultyStore.new(start_memory!(), :mutating_cas),
        busy?: &busy?/1,
        tasks: 2,
        writers: 1,
        rounds: 1,
        timeout_ms: 5_000
      )

    refute report["ok"]
    refute report["invariants"]["casExactlyOneWinnerPerTask"]
    refute report["invariants"]["casLedgerMatchesWinnerPerTask"]
    cas = report["scenarios"]["casContention"]
    assert %{"applied" => 0, "busy" => 2, "committedEvents" => 2, "verifiedTasks" => 0} = cas
    assert [sample | _rest] = cas["mismatchSamples"]
    assert sample =~ "applied writers []"
  end

  test "a stale renewal that mutates before reporting busy fails the run" do
    report =
      Stress.run(
        store: FaultyStore.new(start_memory!(), :mutating_renew),
        busy?: &busy?/1,
        tasks: 2,
        writers: 2,
        rounds: 1,
        timeout_ms: 5_000
      )

    refute report["ok"]
    refute report["invariants"]["fencingStaleLeaseRejected"]
    fencing = report["scenarios"]["leaseFencing"]
    # The retry's final answer looks right; only the state check catches it.
    assert fencing["staleRenewalsRejected"] == 2
    assert fencing["untouchedAfterStale"] == 0
    assert fencing["verifiedTasks"] == 0
    assert report["busyRetries"] >= 2
  end

  test "an invalid store is rejected before any linked process starts" do
    {:links, before} = Process.info(self(), :links)

    assert_raise ArgumentError, ~r/does not export/, fn ->
      Stress.run(store: {String, nil})
    end

    assert {:links, ^before} = Process.info(self(), :links)
  end

  test "command-line arguments split harness and package options" do
    assert {:ok, [tasks: 3, rounds: 2], [pool_size: 4], true} =
             Stress.parse_args(
               ~w(--tasks 3 --pool-size 4 --rounds 2 --json),
               pool_size: :integer
             )

    assert {:ok, [], [], false} = Stress.parse_args([])
    assert {:error, :invalid_arguments} = Stress.parse_args(~w(--pool-size 4))
    assert {:error, :invalid_arguments} = Stress.parse_args(~w(extra))
  end

  test "the text report names failed invariants" do
    report = Stress.run(tasks: 1, writers: 2, rounds: 1, timeout_ms: 5_000)
    assert Enum.at(Stress.format_report(report), -1) == "Invariants: passed"

    failed = put_in(report, ["invariants", "runnerDrained"], false) |> Map.put("ok", false)
    lines = Stress.format_report(failed)
    assert "Invariants: failed" in lines
    assert "  failed: runnerDrained" in lines
  end

  test "configuration rejects unknown, non-positive, and malformed options" do
    assert_raise ArgumentError, ~r/:tasks must be a positive integer/, fn ->
      Stress.run(tasks: 0)
    end

    assert_raise ArgumentError, ~r/stress options must use only/, fn ->
      Stress.run(unknown: 1)
    end

    assert_raise ArgumentError, ~r/:store must be a/, fn ->
      Stress.run(store: :memory)
    end

    assert_raise ArgumentError, ~r/:busy\? must be an arity-1 function/, fn ->
      Stress.run(busy?: true)
    end
  end

  defp busy?(result), do: result == {:error, :database_busy}

  defp start_memory! do
    {:ok, memory} =
      Memory.start_link(
        scope: :shared,
        max_tasks: :infinity,
        max_active_tasks_per_scope: :infinity
      )

    on_exit(fn -> if Process.alive?(memory), do: GenServer.stop(memory) end)
    memory
  end
end
