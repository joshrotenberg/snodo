defmodule Snodo.Extensions.Tasks.SQLite.LiveRepo do
  @moduledoc false

  use Ecto.Repo,
    otp_app: :snodo_tasks_sqlite,
    adapter: Ecto.Adapters.SQLite3
end

defmodule Snodo.Extensions.Tasks.SQLite.MigrationRepo do
  @moduledoc false

  use Ecto.Repo,
    otp_app: :snodo_tasks_sqlite,
    adapter: Ecto.Adapters.SQLite3
end

defmodule Snodo.Extensions.Tasks.SQLite.BusyRepo do
  @moduledoc false

  use Ecto.Repo,
    otp_app: :snodo_tasks_sqlite,
    adapter: Ecto.Adapters.SQLite3
end

defmodule Snodo.Extensions.Tasks.SQLite.LiveExecutor do
  @moduledoc false

  @behaviour Snodo.Extensions.Tasks.WorkExecutor

  @impl true
  def execute(work, _cancellation, state) do
    attempt = Agent.get_and_update(state.counter, &{&1 + 1, &1 + 1})
    send(state.owner, {:sqlite_live_execution, work.idempotency_key, attempt, work, self()})

    if attempt == 1 do
      receive do
        {:complete_sqlite_live_work, result} -> {:completed, result}
      end
    else
      {:completed,
       %{
         "attempt" => attempt,
         "idempotencyKey" => work.idempotency_key,
         "recovered" => true
       }}
    end
  end
end

defmodule Snodo.Extensions.Tasks.SQLite.IntegrationTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Snodo.Context
  alias Snodo.Extensions.Tasks.Event
  alias Snodo.Extensions.Tasks.RetryPolicy
  alias Snodo.Extensions.Tasks.Runner
  alias Snodo.Extensions.Tasks.Snapshot
  alias Snodo.Extensions.Tasks.SQLite.BusyRepo
  alias Snodo.Extensions.Tasks.SQLite.LiveExecutor
  alias Snodo.Extensions.Tasks.SQLite.LiveRepo
  alias Snodo.Extensions.Tasks.SQLite.MigrationRepo
  alias Snodo.Extensions.Tasks.Store
  alias Snodo.Extensions.Tasks.Store.SQLite
  alias Snodo.Extensions.Tasks.Store.SQLite.EventRow
  alias Snodo.Extensions.Tasks.Store.SQLite.Migration
  alias Snodo.Extensions.Tasks.Store.SQLite.Migration.V1, as: MigrationV1
  alias Snodo.Extensions.Tasks.Store.SQLite.Migration.V2, as: MigrationV2
  alias Snodo.Extensions.Tasks.Store.SQLite.Persistence
  alias Snodo.Extensions.Tasks.Store.SQLite.TaskRow
  alias Snodo.Extensions.Tasks.Store.SQLite.Timestamp
  alias Snodo.Extensions.Tasks.Task, as: ProtocolTask
  alias Snodo.Extensions.Tasks.Transition
  alias Snodo.Extensions.Tasks.Work
  alias Snodo.Protocol.V2026_07_28
  alias Snodo.Transport.Context, as: TransportContext

  @migration_version 2_026_082_602
  @migration_v1_version 2_026_082_601
  @migration_v2_version 2_026_082_602
  @lease_ms 10_000
  # Match the documented application baseline while staying below the 10-second
  # test lease. A writer cannot wait until the competing winner's lease expires
  # and then become a second valid claimant. The busy-boundary test uses its own
  # BusyRepo at 25ms and its own store at 1s to provoke :database_busy.
  @busy_timeout_ms 5_000

  # A racer that is waiting out the busy timeout is behaving correctly, so any
  # budget for awaiting one has to exceed it. Deriving this rather than writing
  # a second literal keeps the two from drifting apart: the previous 5s await
  # was shorter than the wait it was supposed to allow.
  @race_await_ms @busy_timeout_ms + 5_000
  @retry_delay_ms 1_500

  setup_all do
    database = unique_database("suite")

    {:ok, bootstrap_repo} = start_repo(LiveRepo, database, @busy_timeout_ms, 1)
    Process.unlink(bootstrap_repo)
    assert :ok = migrate_up!(LiveRepo)
    stop_process(bootstrap_repo)

    # Match the adapter's ordinary pooled default. Exqlite runs every native
    # call on dirty I/O schedulers, so a larger pool can make connection teardown
    # and busy waits consume the executor that the lock holder needs to commit.
    {:ok, repo} = start_repo(LiveRepo, database, @busy_timeout_ms, 5)
    Process.unlink(repo)

    {:ok, busy_repo} = start_repo(BusyRepo, database, 25, 1)
    Process.unlink(busy_repo)

    config =
      SQLite.new!(
        repo: LiveRepo,
        scope: fn context -> context.auth["tenant"] end,
        # A Store transaction can spend the full busy timeout waiting for a
        # competing writer. Its client deadline must outlive that wait too.
        timeout: @race_await_ms,
        reap_batch_size: 100
      )

    busy_config = SQLite.new!(repo: BusyRepo, timeout: 1_000)

    assert :ok = SQLite.check_schema(config)
    assert :ok = SQLite.check_schema(busy_config)
    assert [["wal"]] = query!(LiveRepo, "PRAGMA journal_mode").rows
    assert [[1]] = query!(LiveRepo, "PRAGMA foreign_keys").rows

    on_exit(fn ->
      stop_process(busy_repo)
      stop_process(repo)
      cleanup_database(database)
    end)

    %{
      busy_store: {SQLite, busy_config},
      config: config,
      database: database,
      repo: LiveRepo,
      store: {SQLite, config}
    }
  end

  setup do
    query!(LiveRepo, "DELETE FROM mcp_tasks")
    :ok
  end

  @tag mcp_contract: ["tasks-sqlite-migration"]
  test "an application-owned file Repo explicitly migrates up and down without residue" do
    database = unique_database("migration")
    {:ok, repo} = start_repo(MigrationRepo, database, @busy_timeout_ms, 1)
    Process.unlink(repo)

    try do
      config = SQLite.new!(repo: MigrationRepo)
      assert MigrationRepo.__adapter__() == Ecto.Adapters.SQLite3
      assert {:error, _missing_schema} = SQLite.check_schema(config)
      assert :ok = migrate_up!(MigrationRepo)
      assert :ok = SQLite.check_schema(config)
      assert :ok = migrate_down!(MigrationRepo)

      assert [[0]] =
               query!(
                 MigrationRepo,
                 "SELECT count(*) FROM sqlite_master " <>
                   "WHERE type = 'table' AND name IN " <>
                   "('mcp_task_store_metadata', 'mcp_tasks', 'mcp_task_events')"
               ).rows
    after
      stop_process(repo)
      cleanup_database(database)
    end

    Enum.each(database_files(database), &refute(File.exists?(&1)))
  end

  @tag mcp_contract: ["tasks-sqlite-migration"]
  test "version-one data survives upgrade, rollback, and re-upgrade" do
    assert MigrationV1.current_version() == 1
    assert MigrationV2.current_version() == 2
    assert Migration.current_version() == 2

    database = unique_database("upgrade")
    {:ok, repo} = start_repo(MigrationRepo, database, @busy_timeout_ms, 1)
    Process.unlink(repo)

    try do
      config = SQLite.new!(repo: MigrationRepo)
      store = {SQLite, config}
      task_id = unique_id("upgrade")

      assert :ok = migrate_up!(MigrationRepo, @migration_v1_version, MigrationV1)
      assert {:error, {:unsupported_schema_version, 1}} = SQLite.check_schema(config)

      initial =
        create_task!(store, task_id, "tenant-a", created_at: ProtocolTask.timestamp())

      assert {:ok, ^initial, lease} = Store.claim(store, task_id, "upgrade-owner", @lease_ms)
      completed = event!(Event.completed(%{"migrated" => true}, id: unique_id("upgrade-event")))

      assert {:ok, %Transition{outcome: :applied, snapshot: terminal}} =
               Store.transition(store, task_id, initial.revision, completed, {:worker, lease})

      assert :ok = Store.release(store, lease)
      access = authorize!(store, context("tenant-a"), {:get, task_id})
      assert {:ok, history_before} = SQLite.history(config, task_id, access)

      assert :ok = migrate_up!(MigrationRepo, @migration_v2_version, MigrationV2)
      assert :ok = SQLite.check_schema(config)
      assert {:ok, ^terminal} = Store.get(store, task_id, access)
      assert {:ok, ^history_before} = SQLite.history(config, task_id, access)
      assert [[1]] = migration_index_count(MigrationRepo)

      assert :ok = migrate_down!(MigrationRepo, @migration_v2_version, MigrationV2)
      assert {:error, {:unsupported_schema_version, 1}} = SQLite.check_schema(config)
      assert [[1]] = query!(MigrationRepo, "SELECT count(*) FROM mcp_tasks").rows
      assert [[0]] = migration_index_count(MigrationRepo)

      assert :ok = migrate_up!(MigrationRepo, @migration_v2_version, MigrationV2)
      assert :ok = SQLite.check_schema(config)
      assert {:ok, ^terminal} = Store.get(store, task_id, access)
      assert {:ok, ^history_before} = SQLite.history(config, task_id, access)
    after
      stop_process(repo)
      cleanup_database(database)
    end

    Enum.each(database_files(database), &refute(File.exists?(&1)))
  end

  @tag mcp_contract: ["tasks-sqlite-migration"]
  test "DDL rejects SQLite JSONB blobs and noncanonical JSON text", %{store: store} do
    task_id = unique_id("json-storage-class")
    initial = create_task!(store, task_id)
    assert {:ok, ^initial, lease} = Store.claim(store, task_id, "json-owner", @lease_ms)

    completed = event!(Event.completed(%{"stored" => true}, id: unique_id("json-event")))

    assert {:ok, %Transition{outcome: :applied}} =
             Store.transition(store, task_id, 0, completed, {:worker, lease})

    assert :ok = Store.release(store, lease)

    Enum.each(["snapshot", "authorization_scope"], fn column ->
      assert_raise Exqlite.Error, fn ->
        query!(
          LiveRepo,
          "UPDATE mcp_tasks SET #{column} = jsonb(#{column}) WHERE task_id = ?",
          [task_id]
        )
      end
    end)

    Enum.each(["event", "effects"], fn column ->
      assert_raise Exqlite.Error, fn ->
        query!(
          LiveRepo,
          "UPDATE mcp_task_events SET #{column} = jsonb(#{column}) WHERE task_id = ?",
          [task_id]
        )
      end
    end)

    assert_raise Exqlite.Error, fn ->
      query!(
        LiveRepo,
        "UPDATE mcp_tasks SET snapshot = ? WHERE task_id = ?",
        ["{version: 1}", task_id]
      )
    end

    assert [["text", "text"]] =
             query!(
               LiveRepo,
               "SELECT typeof(snapshot), typeof(authorization_scope) " <>
                 "FROM mcp_tasks WHERE task_id = ?",
               [task_id]
             ).rows

    assert [["text", "text"]] =
             query!(
               LiveRepo,
               "SELECT typeof(event), typeof(effects) " <>
                 "FROM mcp_task_events WHERE task_id = ?",
               [task_id]
             ).rows

    assert %{num_rows: 1} =
             query!(
               LiveRepo,
               "UPDATE mcp_tasks SET snapshot = ? WHERE task_id = ?",
               [~s({"version":3,"revision":1e999}), task_id]
             )

    access = authorize!(store, context("tenant-a"), {:get, task_id})

    assert {:error, {:corrupt_store, ^task_id, {:invalid_snapshot_json, %Jason.DecodeError{}}}} =
             Store.get(store, task_id, access)
  end

  @tag mcp_contract: ["tasks-sqlite-scope"]
  test "scalar authorization scopes create, read, and conceal across tenants", %{store: store} do
    task_id = unique_id("scope")
    snapshot = create_task!(store, task_id, "tenant-a")

    assert {:ok, tenant_a} = authorize(store, context("tenant-a"), {:get, task_id})
    assert {:ok, ^snapshot} = Store.get(store, task_id, tenant_a)

    assert {:ok, tenant_b} = authorize(store, context("tenant-b"), {:get, task_id})
    assert :not_found = Store.get(store, task_id, tenant_b)
    assert :not_found = SQLite.history(elem(store, 1), task_id, tenant_b)
  end

  @tag mcp_contract: ["tasks-sqlite-scope"]
  test "cross-scope transition conceals a corrupt aggregate before decoding it", %{store: store} do
    task_id = unique_id("scope-corruption")
    _snapshot = create_task!(store, task_id, "tenant-a")
    query = from task in TaskRow, where: task.task_id == ^task_id
    assert {1, nil} = LiveRepo.update_all(query, set: [revision: 1])

    tenant_b_cancel = authorize!(store, context("tenant-b"), {:cancel, task_id})
    cancelled = event!(Event.cancelled(id: unique_id("concealed-cancel")))

    assert :not_found =
             Store.transition(store, task_id, 0, cancelled, {:request, tenant_b_cancel})

    tenant_a_get = authorize!(store, context("tenant-a"), {:get, task_id})

    assert {:error, {:corrupt_store, ^task_id, :revision_projection_mismatch}} =
             Store.get(store, task_id, tenant_a_get)
  end

  @tag mcp_contract: ["tasks-sqlite-concurrency"]
  test "two independent exact claims serialize to exactly one winner", %{store: store} do
    task_id = unique_id("exact-claim")
    _snapshot = create_task!(store, task_id)

    results =
      checked_out_race([
        fn -> Store.claim(store, task_id, "owner-a", @lease_ms) end,
        fn -> Store.claim(store, task_id, "owner-b", @lease_ms) end
      ])

    assert Enum.count(results, &match?({:ok, %Snapshot{}, _lease}, &1)) == 1
    assert Enum.count(results, &(&1 == :unavailable)) == 1

    {:ok, _claimed, lease} = Enum.find(results, &match?({:ok, %Snapshot{}, _lease}, &1))
    assert :ok = Store.release(store, lease)
  end

  @tag mcp_contract: ["tasks-sqlite-concurrency"]
  @tag capture_log: true
  test "WAL readers continue while writers wait or fail at the application busy boundary", %{
    busy_store: busy_store,
    store: store
  } do
    wait_id = unique_id("busy-wait")
    timeout_id = unique_id("busy-timeout")
    wait_snapshot = create_task!(store, wait_id)
    timeout_snapshot = create_task!(store, timeout_id)
    holder = hold_writer!()

    try do
      assert scoped_snapshot!(store, wait_id) == wait_snapshot

      assert {:error, :database_busy} =
               Store.claim(busy_store, timeout_id, "short-timeout-owner", @lease_ms)

      assert row!(timeout_id).claim_owner == nil
      assert scoped_snapshot!(store, timeout_id) == timeout_snapshot

      claimant = blocked_claim(store, wait_id, "waiting-owner")
      assert_receive {:sqlite_claim_ready, claimant_process}, 2_000
      send(claimant_process, :run_sqlite_claim)
      assert Task.yield(claimant, 75) == nil

      assert scoped_snapshot!(store, wait_id) == wait_snapshot
      release_writer(holder)

      assert {:ok, ^wait_snapshot, lease} = Task.await(claimant, 3_000)
      assert :ok = Store.release(store, lease)
    after
      release_writer(holder)
    end
  end

  @tag mcp_contract: ["tasks-sqlite-concurrency"]
  test "claim_next serially filters a committed live first claim and takes the second", %{
    store: store
  } do
    created_at = database_now_iso8601()
    first_id = "a-" <> unique_id("queue")
    second_id = "b-" <> unique_id("queue")
    first = create_task!(store, first_id, "tenant-a", created_at: created_at)
    second = create_task!(store, second_id, "tenant-a", created_at: created_at)

    assert {:ok, ^first, first_lease} = Store.claim(store, first_id, "first-owner", @lease_ms)

    assert {:ok, %Snapshot{task: %{id: ^second_id}} = claimed, second_lease} =
             Store.claim_next(store, "next-owner", @lease_ms)

    assert claimed == second
    assert :ok = Store.release(store, second_lease)
    assert :ok = Store.release(store, first_lease)
  end

  @tag mcp_contract: ["tasks-sqlite-concurrency"]
  test "all mutations fail closed inside an application deferred transaction", %{store: store} do
    claimed_id = unique_id("nested-claimed")
    queued_id = unique_id("nested-queued")
    nested_create_id = unique_id("nested-create")
    claimed = create_task!(store, claimed_id)
    _queued = create_task!(store, queued_id)

    assert {:ok, ^claimed, lease} =
             Store.claim(store, claimed_id, "nested-owner", @lease_ms)

    nested_task =
      ProtocolTask.new!(
        id: nested_create_id,
        created_at: database_now_iso8601(),
        poll_interval_ms: 10,
        status_message: "accepted"
      )

    nested_work = Work.new!(nested_create_id, "sqlite/nested", %{})
    nested_access = authorize!(store, context("tenant-a"), {:create, nested_create_id})
    completed = event!(Event.completed(%{"nested" => true}, id: unique_id("nested-event")))

    expected = {:error, :nested_write_transaction_unsupported}

    assert {:ok, results} =
             LiveRepo.transact(
               fn ->
                 {:ok,
                  [
                    Store.create(store, nested_task, nested_work, nested_access),
                    Store.claim(store, queued_id, "nested-claim", @lease_ms),
                    Store.claim_next(store, "nested-next", @lease_ms),
                    Store.renew(store, lease, @lease_ms),
                    Store.release(store, lease),
                    Store.reap(store),
                    Store.transition(store, claimed_id, 0, completed, {:worker, lease})
                  ]}
               end,
               mode: :deferred
             )

    assert results == List.duplicate(expected, 7)

    nested_get = authorize!(store, context("tenant-a"), {:get, nested_create_id})
    assert :not_found = Store.get(store, nested_create_id, nested_get)
    assert {:ok, ^claimed} = Store.worker_snapshot(store, claimed_id, lease)
    assert :ok = Store.release(store, lease)
  end

  @tag mcp_contract: ["tasks-sqlite-ledger"]
  test "concurrent terminal compare-and-set permits one immutable winner", %{store: store} do
    task_id = unique_id("terminal-cas")
    initial = create_task!(store, task_id)
    assert {:ok, ^initial, lease} = Store.claim(store, task_id, "terminal-owner", @lease_ms)

    completed = event!(Event.completed(%{"winner" => "completed"}, id: unique_id("complete")))
    failed = event!(Event.failed(error("failed"), "failed", id: unique_id("failed")))

    results =
      checked_out_race([
        fn -> Store.transition(store, task_id, 0, completed, {:worker, lease}) end,
        fn -> Store.transition(store, task_id, 0, failed, {:worker, lease}) end
      ])

    assert Enum.count(results, &match?({:ok, %Transition{outcome: :applied}}, &1)) == 1
    assert Enum.count(results, &match?({:conflict, %Snapshot{}}, &1)) == 1

    terminal = scoped_snapshot!(store, task_id)
    assert terminal.revision == 1
    assert terminal.task.status in [:completed, :failed]
    assert event_count(task_id) == 1
    assert :ok = Store.release(store, lease)
  end

  @tag mcp_contract: ["tasks-sqlite-ledger"]
  test "identical events replay once and changed ID reuse is rejected", %{store: store} do
    task_id = unique_id("event-replay")
    initial = create_task!(store, task_id)
    assert {:ok, ^initial, lease} = Store.claim(store, task_id, "ledger-owner", @lease_ms)

    event_id = unique_id("stable-event")
    completed = event!(Event.completed(%{"value" => 1}, id: event_id))

    results =
      checked_out_race([
        fn -> Store.transition(store, task_id, 0, completed, {:worker, lease}) end,
        fn -> Store.transition(store, task_id, 0, completed, {:worker, lease}) end
      ])

    assert {:ok, %Transition{outcome: :applied} = applied} =
             Enum.find(results, &match?({:ok, %Transition{outcome: :applied}}, &1))

    assert {:ok, %Transition{outcome: :duplicate} = duplicate} =
             Enum.find(results, &match?({:ok, %Transition{outcome: :duplicate}}, &1))

    assert duplicate.event_revision == applied.event_revision
    assert duplicate.committed_at == applied.committed_at
    assert duplicate.effects == applied.effects

    changed = event!(Event.failed(error("changed"), "changed", id: event_id))

    assert {:error, :event_id_reused} =
             Store.transition(store, task_id, 1, changed, {:worker, lease})

    assert event_count(task_id) == 1
    assert %Snapshot{revision: 1, task: %{status: :completed}} = scoped_snapshot!(store, task_id)
    assert :ok = Store.release(store, lease)
  end

  @tag mcp_contract: ["tasks-sqlite-ledger"]
  test "an event revision constraint failure rolls back the aggregate update", %{store: store} do
    task_id = unique_id("event-rollback")
    initial = create_task!(store, task_id)
    assert {:ok, ^initial, lease} = Store.claim(store, task_id, "rollback-owner", @lease_ms)

    conflicting = event!(Event.completed(%{"seeded" => true}, id: unique_id("conflicting")))
    assert {:ok, encoded_effects} = Persistence.encode_effects(%{})
    assert {:ok, encoded_event} = Persistence.encode_json(Event.to_map(conflicting))

    assert {1, nil} =
             LiveRepo.insert_all(EventRow, [
               %{
                 task_id: task_id,
                 event_id: conflicting.id,
                 row_format: Persistence.row_format(),
                 event: encoded_event,
                 event_kind: "completed",
                 event_revision: 1,
                 committed_at_us: database_now_us(),
                 effects: encoded_effects
               }
             ])

    attempted = event!(Event.completed(%{"attempted" => true}, id: unique_id("attempted")))

    assert {:error, _constraint_failure} =
             Store.transition(store, task_id, 0, attempted, {:worker, lease})

    persisted = row!(task_id)
    assert persisted.revision == 0
    assert persisted.status == "working"
    assert {:ok, ^initial} = Persistence.decode_task_row(persisted)
    assert event_count(task_id) == 1
    assert :ok = Store.release(store, lease)
  end

  @tag mcp_contract: ["tasks-sqlite-ledger"]
  test "domain errors mentioning database busy are not mistaken for lock contention", %{
    store: store
  } do
    task_id = unique_id("domain-busy-phrase")
    initial = create_task!(store, task_id)
    assert {:ok, ^initial, lease} = Store.claim(store, task_id, "domain-owner", @lease_ms)

    invalid = %Event{
      id: unique_id("invalid-version"),
      version: "database is busy",
      kind: :completed,
      data: %{"result" => %{}}
    }

    assert {:error, {:unsupported_event_version, "database is busy"}} =
             Store.transition(store, task_id, 0, invalid, {:worker, lease})

    assert scoped_snapshot!(store, task_id) == initial
    assert event_count(task_id) == 0
    assert :ok = Store.release(store, lease)
  end

  @tag mcp_contract: ["tasks-sqlite-leases"]
  test "renewal replaces exact expiry and makes the previous lease stale", %{store: store} do
    task_id = unique_id("renew")
    initial = create_task!(store, task_id)
    assert {:ok, ^initial, lease} = Store.claim(store, task_id, "renew-owner", 20_000)
    assert {:ok, renewed} = Store.renew(store, lease, 2_000)
    assert renewed.expires_at_us < lease.expires_at_us
    refute renewed.expires_at_us == lease.expires_at_us

    assert {:error, :stale_lease} = Store.worker_snapshot(store, task_id, lease)
    assert {:error, :stale_lease} = Store.release(store, lease)
    assert {:ok, ^initial} = Store.worker_snapshot(store, task_id, renewed)
    assert :ok = Store.release(store, renewed)
  end

  @tag mcp_contract: ["tasks-sqlite-leases"]
  @tag capture_log: true
  test "renew preserves database busy errors instead of reporting a stale lease", %{
    busy_store: busy_store
  } do
    task_id = unique_id("renew-busy")
    initial = create_task!(busy_store, task_id)

    assert {:ok, ^initial, lease} =
             Store.claim(busy_store, task_id, "busy-renew-owner", @lease_ms)

    claimed_before = row!(task_id)
    holder = hold_writer!()

    try do
      assert {:error, :database_busy} = Store.renew(busy_store, lease, 20_000)
      assert claim_identity(row!(task_id)) == claim_identity(claimed_before)
      assert row!(task_id).claim_expires_at_us == claimed_before.claim_expires_at_us
    after
      release_writer(holder)
    end

    assert :ok = eventually_release(busy_store, lease)
  end

  @tag mcp_contract: ["tasks-sqlite-leases"]
  test "database-expired claims increment generation and fence the prior worker", %{store: store} do
    task_id = unique_id("expired")
    initial = create_task!(store, task_id)
    assert {:ok, ^initial, first} = Store.claim(store, task_id, "first-owner", @lease_ms)
    backdate_claim!(task_id)

    assert {:ok, ^initial, second} = Store.claim(store, task_id, "second-owner", @lease_ms)
    assert second.generation == first.generation + 1
    refute second.token == first.token

    stale_event = event!(Event.completed(%{"stale" => true}, id: unique_id("stale")))

    assert {:error, :stale_lease} =
             Store.transition(store, task_id, 0, stale_event, {:worker, first})

    assert {:error, :stale_lease} = Store.release(store, first)
    assert {:ok, ^initial} = Store.worker_snapshot(store, task_id, second)
    assert :ok = Store.release(store, second)
  end

  @tag mcp_contract: ["tasks-sqlite-time"]
  test "retry timing uses exact epoch projections and samples time after writer serialization", %{
    config: config,
    store: store
  } do
    task_id = unique_id("retry")

    work =
      Work.new!(task_id, "sqlite/retry", %{}, retry_policy: RetryPolicy.new!([@retry_delay_ms]))

    initial = create_task!(store, task_id, "tenant-a", work: work)
    assert {:ok, ^initial, lease} = Store.claim(store, task_id, "retry-owner", @lease_ms)

    retry = event!(Event.retry_requested(error("temporary"), "retry", id: unique_id("retry")))
    before_commit_us = database_now_us()

    assert {:ok, %Transition{snapshot: scheduled} = transition} =
             Store.transition(store, task_id, 0, retry, {:worker, lease})

    after_commit_us = database_now_us()
    assert {:ok, committed_at_us} = Timestamp.parse(transition.committed_at)
    assert {:ok, retry_at_us} = Timestamp.parse(scheduled.retry_at)

    assert scheduled.retry_count == 1
    assert transition.effects.retry.delay_ms == @retry_delay_ms
    assert transition.effects.retry.retry_at == scheduled.retry_at
    assert retry_at_us - committed_at_us == @retry_delay_ms * 1_000
    assert committed_at_us >= before_commit_us
    assert committed_at_us <= after_commit_us + 1_000

    persisted = row!(task_id)
    assert persisted.retry_at_us == retry_at_us
    assert is_integer(persisted.created_at_us)
    assert is_integer(persisted.claim_expires_at_us)

    assert [[^committed_at_us]] =
             query!(
               LiveRepo,
               "SELECT committed_at_us FROM mcp_task_events " <>
                 "WHERE task_id = ? AND event_id = ?",
               [task_id, retry.id]
             ).rows

    assert :ok = Store.release(store, lease)
    assert {:deferred, remaining_ms} = Store.claim(store, task_id, "early-owner", @lease_ms)
    assert remaining_ms > 0

    # A commit timestamp may be the one-microsecond monotonic successor of the
    # millisecond-resolution SQLite clock. Remaining delay rounds up for safe
    # scheduling, so that case is one millisecond above the configured delay.
    assert remaining_ms <= @retry_delay_ms + 1

    holder = hold_rearmed_retry!(task_id, retry.id, scheduled, transition)
    rearmed_retry_at_us = holder.retry_at_us
    claimant = blocked_claim(store, task_id, "due-owner")

    try do
      assert database_now_us() < rearmed_retry_at_us
      assert_receive {:sqlite_claim_ready, claimant_process}, 2_000
      send(claimant_process, :run_sqlite_claim)
      assert Task.yield(claimant, 75) == nil
      wait_until_database_time!(rearmed_retry_at_us)
      release_writer(holder)

      assert {:ok, %Snapshot{retry_count: 1}, due_lease} = Task.await(claimant, 3_000)
      assert {:ok, %{checked: 1, errors: []}} = SQLite.audit(config, limit: 10)
      assert :ok = Store.release(store, due_lease)
    after
      release_writer(holder)
      shutdown_task(claimant)
    end
  end

  @tag mcp_contract: ["tasks-sqlite-time"]
  test "TTL reaping deletes the aggregate and cascades its event ledger", %{store: store} do
    expiring_id = unique_id("ttl")
    survivor_id = unique_id("no-ttl")
    created_at = (database_now_us() - 2_000_000) |> Timestamp.format() |> ok!()
    initial = create_task!(store, expiring_id, "tenant-a", created_at: created_at, ttl_ms: 1)
    _survivor = create_task!(store, survivor_id, "tenant-a", created_at: created_at)
    assert {:ok, ^initial, lease} = Store.claim(store, expiring_id, "ttl-owner", @lease_ms)

    completed = event!(Event.completed(%{"expired" => true}, id: unique_id("ttl-event")))

    assert {:ok, %Transition{outcome: :applied}} =
             Store.transition(store, expiring_id, 0, completed, {:worker, lease})

    assert :ok = Store.release(store, lease)
    assert event_count(expiring_id) == 1
    assert {:ok, [^expiring_id]} = Store.reap(store)
    assert table_count("mcp_tasks", expiring_id) == 0
    assert event_count(expiring_id) == 0
    assert table_count("mcp_tasks", survivor_id) == 1
  end

  @tag mcp_contract: ["tasks-sqlite-recovery"]
  @tag capture_log: true
  test "a replacement Runner recovers a hard-dead Runner with identical Work", %{store: store} do
    task_id = unique_id("runner-recovery")

    work =
      Work.new!(task_id, "sqlite/recovery", %{"mode" => "hard-death"},
        retry_policy: RetryPolicy.new!([0])
      )

    initial = create_task!(store, task_id, "tenant-a", work: work)
    assert {:ok, ^initial, seed_lease} = Store.claim(store, task_id, "seed-owner", @lease_ms)

    retry = event!(Event.retry_requested(error("seed"), "seed retry", id: unique_id("seed")))

    assert {:ok, %Transition{snapshot: seeded}} =
             Store.transition(store, task_id, 0, retry, {:worker, seed_lease})

    assert seeded.retry_count == 1
    assert :ok = Store.release(store, seed_lease)
    make_retry_due!(task_id)

    counter = start_supervised!({Agent, fn -> 0 end})
    executor = {LiveExecutor, %{counter: counter, owner: self()}}
    first_runner = start_runner!(store, executor, "runner-one")
    on_exit(fn -> stop_process(first_runner) end)

    assert_receive {:sqlite_live_execution, ^task_id, 1, first_work, first_worker}, 2_000
    assert first_work == work

    claimed_before_kill = row!(task_id)
    assert claimed_before_kill.claim_owner == "runner-one"
    assert claimed_before_kill.lease_generation == 2
    refute is_nil(claimed_before_kill.claim_token)
    assert claimed_before_kill.claim_expires_at_us > database_now_us()

    runner_monitor = Process.monitor(first_runner)
    worker_monitor = Process.monitor(first_worker)
    Process.exit(first_runner, :kill)
    assert_receive {:DOWN, ^runner_monitor, :process, ^first_runner, :killed}, 2_000
    assert_receive {:DOWN, ^worker_monitor, :process, ^first_worker, _reason}, 2_000

    persisted_after_kill = row!(task_id)
    assert claim_identity(persisted_after_kill) == claim_identity(claimed_before_kill)
    assert persisted_after_kill.claim_expires_at_us == claimed_before_kill.claim_expires_at_us

    backdate_claim!(task_id)
    second_runner = start_runner!(store, executor, "runner-two")
    on_exit(fn -> stop_process(second_runner) end)

    assert_receive {:sqlite_live_execution, ^task_id, 2, second_work, _worker}, 2_000
    assert second_work == work

    completed = eventually_snapshot!(store, task_id, &(&1.task.status == :completed))
    assert completed.work == work
    assert completed.retry_count == 1
    assert completed.task.result["idempotencyKey"] == task_id
    assert Agent.get(counter, & &1) == 2

    final_row = eventually_row!(task_id, &is_nil(&1.claim_owner))
    assert final_row.lease_generation == 3

    access = authorize!(store, context("tenant-a"), {:get, task_id})
    assert {:ok, history} = SQLite.history(elem(store, 1), task_id, access)
    assert Enum.map(history, & &1.event.kind) == [:retry_requested, :completed]
  end

  defp start_repo(repo, database, busy_timeout, pool_size) do
    repo.start_link(
      database: database,
      pool_size: pool_size,
      journal_mode: :wal,
      foreign_keys: :on,
      busy_timeout: busy_timeout,
      default_transaction_mode: :deferred,
      # DBConnection also sheds connections when checkout queueing stays above
      # queue_target for queue_interval. With writers now waiting out the busy
      # timeout above, queueing is longer by design, so these margins are
      # widened to match. Both are test-harness values for deliberate
      # contention and say nothing about production pool settings.
      queue_target: 500,
      queue_interval: 5_000,
      log: false
    )
  end

  defp start_runner!(store, executor, owner_id) do
    {:ok, runner} =
      Runner.start_link(
        store: store,
        executor: executor,
        recover: true,
        owner_id: owner_id,
        lease_ms: 30_000,
        heartbeat_ms: 20_000,
        recovery_interval_ms: 60_000
      )

    Process.unlink(runner)
    runner
  end

  defp create_task!(store, task_id, tenant \\ "tenant-a", opts \\ []) do
    created_at = Keyword.get_lazy(opts, :created_at, &database_now_iso8601/0)

    task =
      ProtocolTask.new!(
        id: task_id,
        created_at: created_at,
        ttl_ms: Keyword.get(opts, :ttl_ms),
        poll_interval_ms: 10,
        status_message: "accepted"
      )

    work = Keyword.get_lazy(opts, :work, fn -> Work.new!(task_id, "sqlite/test", %{}) end)
    access = authorize!(store, context(tenant), {:create, task_id})
    assert {:ok, snapshot} = Store.create(store, task, work, access)
    snapshot
  end

  defp scoped_snapshot!(store, task_id, tenant \\ "tenant-a") do
    access = authorize!(store, context(tenant), {:get, task_id})
    assert {:ok, snapshot} = Store.get(store, task_id, access)
    snapshot
  end

  defp checked_out_race(functions) do
    gate = make_ref()
    parent = self()

    tasks = Enum.map(functions, &start_checked_out_racer(&1, parent, gate))

    ready =
      Enum.map(tasks, fn _task ->
        assert_receive {:sqlite_race_ready, ^gate, process}, 2_000
        process
      end)

    Enum.each(ready, &send(&1, {:run_sqlite_race, gate}))
    Enum.map(tasks, &Task.await(&1, @race_await_ms))
  end

  defp start_checked_out_racer(function, parent, gate) do
    Task.async(fn ->
      result =
        LiveRepo.checkout(
          fn ->
            send(parent, {:sqlite_race_ready, gate, self()})

            receive do
              {:run_sqlite_race, ^gate} -> function.()
            end
          end,
          timeout: @race_await_ms
        )

      # SQLITE_BUSY disconnects the checked-out Exqlite connection. Retry the
      # documented backpressure result only after returning that connection to
      # the pool, while the winning claim's lease is still live.
      if result == {:error, :database_busy}, do: function.(), else: result
    end)
  end

  defp hold_writer! do
    gate = make_ref()
    parent = self()

    task = Task.async(fn -> checked_out_writer_holder(parent, gate) end)

    assert_receive {:sqlite_writer_held, ^gate}, 2_000
    %{task: task, gate: gate}
  end

  defp hold_rearmed_retry!(task_id, event_id, snapshot, transition) do
    gate = make_ref()
    parent = self()

    task =
      Task.async(fn ->
        LiveRepo.checkout(fn ->
          transact_rearmed_retry(task_id, event_id, snapshot, transition, parent, gate)
        end)
      end)

    assert_receive {:sqlite_retry_rearmed, ^gate, retry_at_us}, 2_000
    %{task: task, gate: gate, retry_at_us: retry_at_us}
  end

  defp transact_rearmed_retry(task_id, event_id, snapshot, transition, parent, gate) do
    LiveRepo.transact(
      fn ->
        retry_at_us = rearm_retry!(task_id, event_id, snapshot, transition)
        send(parent, {:sqlite_retry_rearmed, gate, retry_at_us})
        await_writer_release(gate)
      end,
      mode: :immediate
    )
  end

  defp rearm_retry!(task_id, event_id, snapshot, transition) do
    assert {:ok, prior_committed_at_us} = Timestamp.parse(transition.committed_at)
    committed_at_us = max(database_now_us(), prior_committed_at_us + 1)
    retry_at_us = committed_at_us + @retry_delay_ms * 1_000
    assert {:ok, committed_at} = Timestamp.format(committed_at_us)
    assert {:ok, retry_at} = Timestamp.format(retry_at_us)

    updated_task = %{snapshot.task | last_updated_at: committed_at}
    updated_snapshot = %{snapshot | task: updated_task, retry_at: retry_at}
    assert {:ok, projected} = Persistence.project_snapshot(updated_snapshot)

    updated_retry = %{transition.effects.retry | retry_at: retry_at}
    assert {:ok, encoded_effects} = Persistence.encode_effects(%{retry: updated_retry})

    task_query = from task in TaskRow, where: task.task_id == ^task_id

    assert {1, nil} =
             LiveRepo.update_all(task_query,
               set: [snapshot: projected.snapshot, retry_at_us: projected.retry_at_us]
             )

    event_query =
      from event in EventRow,
        where: event.task_id == ^task_id,
        where: event.event_id == ^event_id

    assert {1, nil} =
             LiveRepo.update_all(event_query,
               set: [committed_at_us: committed_at_us, effects: encoded_effects]
             )

    retry_at_us
  end

  defp checked_out_writer_holder(parent, gate) do
    LiveRepo.checkout(fn -> transact_writer_holder(parent, gate) end)
  end

  defp transact_writer_holder(parent, gate) do
    LiveRepo.transact(
      fn ->
        send(parent, {:sqlite_writer_held, gate})
        await_writer_release(gate)
      end,
      mode: :immediate
    )
  end

  defp await_writer_release(gate) do
    receive do
      {:release_sqlite_writer, ^gate} -> {:ok, :released}
    after
      5_000 -> {:error, :writer_release_timeout}
    end
  end

  defp release_writer(%{task: %Task{pid: pid} = task, gate: gate}) do
    if Process.alive?(pid) do
      send(pid, {:release_sqlite_writer, gate})
      assert {:ok, :released} = Task.await(task, 2_000)
    end

    :ok
  end

  defp blocked_claim(store, task_id, owner_id) do
    parent = self()

    Task.async(fn ->
      LiveRepo.checkout(
        fn ->
          send(parent, {:sqlite_claim_ready, self()})

          receive do
            :run_sqlite_claim -> Store.claim(store, task_id, owner_id, @lease_ms)
          after
            5_000 -> raise "timed out waiting to start SQLite claim"
          end
        end,
        timeout: @race_await_ms
      )
    end)
  end

  defp eventually_snapshot!(store, task_id, predicate) do
    deadline = System.monotonic_time(:millisecond) + 3_000
    eventually_snapshot(store, task_id, predicate, deadline)
  end

  defp eventually_release(store, lease) do
    deadline = System.monotonic_time(:millisecond) + 2_000
    eventually_release(store, lease, deadline)
  end

  defp eventually_release(store, lease, deadline) do
    case Store.release(store, lease) do
      :ok ->
        :ok

      {:error, reason} when reason != :stale_lease ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, reason}
        else
          Process.sleep(10)
          eventually_release(store, lease, deadline)
        end

      error ->
        error
    end
  end

  defp eventually_snapshot(store, task_id, predicate, deadline) do
    snapshot = scoped_snapshot!(store, task_id)

    cond do
      predicate.(snapshot) ->
        snapshot

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("task did not reach expected state")

      true ->
        Process.sleep(10)
        eventually_snapshot(store, task_id, predicate, deadline)
    end
  end

  defp eventually_row!(task_id, predicate) do
    deadline = System.monotonic_time(:millisecond) + 3_000
    eventually_row(task_id, predicate, deadline)
  end

  defp eventually_row(task_id, predicate, deadline) do
    row = row!(task_id)

    cond do
      predicate.(row) ->
        row

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("row did not reach expected state")

      true ->
        Process.sleep(10)
        eventually_row(task_id, predicate, deadline)
    end
  end

  defp make_retry_due!(task_id) do
    row = row!(task_id)
    assert {:ok, snapshot} = Persistence.decode_task_row(row)
    due_at_us = database_now_us() - 1_000
    assert {:ok, due_at} = Timestamp.format(due_at_us)
    updated_snapshot = %{snapshot | retry_at: due_at}
    assert {:ok, projected} = Persistence.project_snapshot(updated_snapshot)
    query = from task in TaskRow, where: task.task_id == ^task_id

    assert {1, nil} =
             LiveRepo.update_all(query,
               set: [
                 snapshot: projected.snapshot,
                 snapshot_format: projected.snapshot_format,
                 retry_at_us: projected.retry_at_us
               ]
             )
  end

  defp backdate_claim!(task_id) do
    query = from task in TaskRow, where: task.task_id == ^task_id

    assert {1, nil} =
             LiveRepo.update_all(query, set: [claim_expires_at_us: database_now_us() - 1_000])
  end

  defp wait_until_database_time!(target_us) do
    deadline = System.monotonic_time(:millisecond) + 3_000
    wait_until_database_time(target_us, deadline)
  end

  defp wait_until_database_time(target_us, deadline) do
    cond do
      database_now_us() >= target_us ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("SQLite clock did not reach target")

      true ->
        Process.sleep(5)
        wait_until_database_time(target_us, deadline)
    end
  end

  defp row!(task_id) do
    query = from task in TaskRow, where: task.task_id == ^task_id
    LiveRepo.one!(query)
  end

  defp event_count(task_id), do: table_count("mcp_task_events", task_id)

  defp table_count(table, task_id) do
    assert table in ["mcp_tasks", "mcp_task_events"]

    assert [[count]] =
             query!(LiveRepo, "SELECT count(*) FROM #{table} WHERE task_id = ?", [task_id]).rows

    count
  end

  defp database_now_iso8601, do: database_now_us() |> Timestamp.format() |> ok!()

  defp database_now_us do
    assert [[now_us]] =
             query!(LiveRepo, """
             SELECT
               CAST(strftime('%s', 'now') AS INTEGER) * 1000000 +
               CAST(substr(strftime('%f', 'now'), 4, 3) AS INTEGER) * 1000
             """).rows

    now_us
  end

  defp migrate_up!(repo) do
    migrate_up!(repo, @migration_version, Migration)
  end

  defp migrate_up!(repo, version, module) do
    case Ecto.Migrator.up(repo, version, module, log: false) do
      :ok -> :ok
      :already_up -> :ok
    end
  end

  defp migrate_down!(repo) do
    migrate_down!(repo, @migration_version, Migration)
  end

  defp migrate_down!(repo, version, module) do
    case Ecto.Migrator.down(repo, version, module, log: false) do
      :ok -> :ok
      :already_down -> :ok
    end
  end

  defp migration_index_count(repo) do
    query!(
      repo,
      "SELECT count(*) FROM sqlite_master " <>
        "WHERE type = 'index' AND name = 'mcp_task_events_committed'"
    ).rows
  end

  defp query!(repo, sql, params \\ []),
    do: Ecto.Adapters.SQL.query!(repo, sql, params, log: false)

  defp unique_database(label) do
    Path.join(
      System.tmp_dir!(),
      "snodo_tasks_sqlite_#{label}_#{System.unique_integer([:positive, :monotonic])}.sqlite3"
    )
  end

  defp database_files(database),
    do: [database, database <> "-wal", database <> "-shm", database <> "-journal"]

  defp cleanup_database(database) do
    Enum.each(database_files(database), fn path ->
      case File.rm(path) do
        :ok -> :ok
        {:error, :enoent} -> :ok
        {:error, reason} -> raise "could not remove #{path}: #{inspect(reason)}"
      end
    end)
  end

  defp shutdown_task(%Task{pid: pid} = task) do
    if Process.alive?(pid), do: Task.shutdown(task, :brutal_kill)
    :ok
  end

  defp stop_process(process) do
    if is_pid(process) and Process.alive?(process), do: GenServer.stop(process, :normal, 5_000)
    :ok
  end

  defp claim_identity(row),
    do: Map.take(row, [:claim_owner, :claim_token, :lease_generation])

  defp authorize(store, context, action), do: Store.authorize(store, context, action)

  defp authorize!(store, context, action) do
    assert {:ok, access} = authorize(store, context, action)
    access
  end

  defp event!({:ok, %Event{} = event}), do: event
  defp ok!({:ok, value}), do: value

  defp error(message), do: %{"code" => -32_603, "message" => message}

  defp unique_id(label),
    do: label <> "-" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))

  defp context(tenant) do
    %Context{
      protocol_version: V2026_07_28.version(),
      protocol: V2026_07_28,
      transport: %TransportContext{transport: :direct},
      auth: %{"tenant" => tenant}
    }
  end
end
