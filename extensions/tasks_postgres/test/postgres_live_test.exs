defmodule MCP.Extensions.Tasks.Postgres.LiveRepo do
  @moduledoc false

  use Ecto.Repo,
    otp_app: :mcp_ex_tasks_postgres,
    adapter: Ecto.Adapters.Postgres
end

defmodule MCP.Extensions.Tasks.Postgres.LiveExecutor do
  @moduledoc false

  @behaviour MCP.Extensions.Tasks.WorkExecutor

  @impl true
  def execute(work, _cancellation, state) do
    attempt = Agent.get_and_update(state.counter, &{&1 + 1, &1 + 1})
    send(state.owner, {:postgres_live_execution, work.idempotency_key, attempt, work, self()})

    if attempt == 1 do
      receive do
        {:complete_postgres_live_work, result} -> {:completed, result}
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

defmodule MCP.Extensions.Tasks.Postgres.LiveTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias MCP.Context
  alias MCP.Extensions.Tasks.Event
  alias MCP.Extensions.Tasks.Postgres.LiveExecutor
  alias MCP.Extensions.Tasks.Postgres.LiveRepo
  alias MCP.Extensions.Tasks.RetryPolicy
  alias MCP.Extensions.Tasks.Runner
  alias MCP.Extensions.Tasks.Snapshot
  alias MCP.Extensions.Tasks.Store
  alias MCP.Extensions.Tasks.Store.Postgres
  alias MCP.Extensions.Tasks.Store.Postgres.EventRow
  alias MCP.Extensions.Tasks.Store.Postgres.Migration
  alias MCP.Extensions.Tasks.Store.Postgres.Migration.V1, as: MigrationV1
  alias MCP.Extensions.Tasks.Store.Postgres.Migration.V2, as: MigrationV2
  alias MCP.Extensions.Tasks.Store.Postgres.Persistence
  alias MCP.Extensions.Tasks.Store.Postgres.TaskRow
  alias MCP.Extensions.Tasks.Task, as: ProtocolTask
  alias MCP.Extensions.Tasks.Transition
  alias MCP.Extensions.Tasks.Work
  alias MCP.Protocol.V2026_07_28
  alias MCP.Transport.Context, as: TransportContext

  @moduletag :postgres_live
  @moduletag timeout: 20_000

  @migration_version 2_026_082_502
  @migration_v1_version 2_026_082_501
  @migration_v2_version 2_026_082_502
  @lease_ms 10_000
  @retry_delay_ms 2_000
  @session_timezone "Asia/Kathmandu"
  @timezone_retry_delay_ms 2_000
  @timezone_ttl_ms 3_000

  setup_all do
    database_url =
      case System.get_env("MCP_TASKS_DATABASE_URL") do
        url when is_binary(url) and url != "" -> url
        _missing -> flunk("MCP_TASKS_DATABASE_URL is required for PostgreSQL live tests")
      end

    {:ok, repo} =
      LiveRepo.start_link(
        url: database_url,
        pool_size: 12,
        queue_target: 50,
        queue_interval: 1_000,
        parameters: [timezone: @session_timezone]
      )

    Process.unlink(repo)

    on_exit(fn ->
      if Process.alive?(repo), do: Supervisor.stop(repo, :normal, 5_000)
    end)

    schema = unique_schema("suite")
    create_schema!(schema)

    on_exit(fn -> drop_schema!(schema) end)

    migrate_up!(schema)

    config =
      Postgres.new!(
        repo: LiveRepo,
        prefix: schema,
        scope: fn context -> context.auth["tenant"] end,
        timeout: 5_000,
        lock_timeout_ms: 4_000,
        reap_batch_size: 100
      )

    assert :ok = Postgres.check_schema(config)

    %{config: config, repo: LiveRepo, schema: schema, store: {Postgres, config}}
  end

  setup %{schema: schema} do
    query!("TRUNCATE TABLE #{qualified(schema, "mcp_tasks")} CASCADE")
    :ok
  end

  @tag mcp_contract: ["tasks-postgres-live-migration"]
  test "an application-owned Repo runs the shipped migration up, checks it, and rolls it down" do
    schema = unique_schema("migration")
    create_schema!(schema)

    try do
      config = Postgres.new!(repo: LiveRepo, prefix: schema)
      assert LiveRepo.__adapter__() == Ecto.Adapters.Postgres
      assert {:error, {:database_error, _exception}} = Postgres.check_schema(config)
      assert :ok = migrate_up!(schema)
      assert :ok = Postgres.check_schema(config)
      assert :ok = migrate_down!(schema)
      assert [[nil]] = query!("SELECT to_regclass($1)", [schema <> ".mcp_tasks"]).rows
    after
      drop_schema!(schema)
    end
  end

  @tag mcp_contract: ["tasks-postgres-live-migration"]
  test "version-one data survives upgrade, rollback, and re-upgrade" do
    schema = unique_schema("upgrade")
    create_schema!(schema)

    try do
      config = Postgres.new!(repo: LiveRepo, prefix: schema)
      store = {Postgres, config}
      task_id = unique_id("upgrade")

      assert :ok = migrate_up!(schema, @migration_v1_version, MigrationV1)
      assert {:error, {:unsupported_schema_version, 1}} = Postgres.check_schema(config)

      initial = create_task!(store, task_id)
      assert {:ok, ^initial, lease} = Store.claim(store, task_id, "upgrade-owner", @lease_ms)
      completed = event!(Event.completed(%{"migrated" => true}, id: unique_id("upgrade-event")))

      assert {:ok, %Transition{outcome: :applied, snapshot: terminal}} =
               Store.transition(store, task_id, initial.revision, completed, {:worker, lease})

      assert :ok = Store.release(store, lease)
      access = authorize!(store, context("tenant-a"), {:get, task_id})
      assert {:ok, history_before} = Postgres.history(config, task_id, access)

      assert :ok = migrate_up!(schema, @migration_v2_version, MigrationV2)
      assert :ok = Postgres.check_schema(config)
      assert {:ok, ^terminal} = Store.get(store, task_id, access)
      assert {:ok, ^history_before} = Postgres.history(config, task_id, access)
      assert [[1]] = migration_index_count(schema)

      assert :ok = migrate_down!(schema, @migration_v2_version, MigrationV2)
      assert {:error, {:unsupported_schema_version, 1}} = Postgres.check_schema(config)
      assert [[1]] = query!("SELECT count(*) FROM #{qualified(schema, "mcp_tasks")}").rows
      assert [[0]] = migration_index_count(schema)

      assert :ok = migrate_up!(schema, @migration_v2_version, MigrationV2)
      assert :ok = Postgres.check_schema(config)
      assert {:ok, ^terminal} = Store.get(store, task_id, access)
      assert {:ok, ^history_before} = Postgres.history(config, task_id, access)
    after
      drop_schema!(schema)
    end
  end

  @tag mcp_contract: ["tasks-postgres-live-scope"]
  test "scalar authorization scopes create, read, and conceal across tenants", %{store: store} do
    task_id = unique_id("scope")
    snapshot = create_task!(store, task_id, "tenant-a")

    assert {:ok, tenant_a} = authorize(store, context("tenant-a"), {:get, task_id})
    assert {:ok, ^snapshot} = Store.get(store, task_id, tenant_a)

    assert {:ok, tenant_b} = authorize(store, context("tenant-b"), {:get, task_id})
    assert :not_found = Store.get(store, task_id, tenant_b)
    assert :not_found = Postgres.history(elem(store, 1), task_id, tenant_b)
  end

  @tag mcp_contract: ["tasks-postgres-live-concurrency"]
  test "two independent exact claims have exactly one winner", %{store: store} do
    task_id = unique_id("exact-claim")
    _snapshot = create_task!(store, task_id)

    results =
      race([
        fn -> Store.claim(store, task_id, "owner-a", @lease_ms) end,
        fn -> Store.claim(store, task_id, "owner-b", @lease_ms) end
      ])

    assert Enum.count(results, &match?({:ok, %Snapshot{}, _lease}, &1)) == 1
    assert Enum.count(results, &(&1 == :unavailable)) == 1

    {:ok, _claimed, lease} = Enum.find(results, &match?({:ok, %Snapshot{}, _lease}, &1))
    assert :ok = Store.release(store, lease)
  end

  @tag mcp_contract: ["tasks-postgres-live-concurrency"]
  test "claim_next skips a locked first row and claims the second", %{
    schema: schema,
    store: store
  } do
    created_at = database_now() |> DateTime.to_iso8601()
    first_id = "a-" <> unique_id("skip-locked")
    second_id = "b-" <> unique_id("skip-locked")

    _first = create_task!(store, first_id, "tenant-a", created_at: created_at)
    _second = create_task!(store, second_id, "tenant-a", created_at: created_at)

    holder = hold_row!(schema, first_id)

    try do
      assert {claimant_backend_pid, {:ok, %Snapshot{task: %{id: ^second_id}}, lease}} =
               checked_out(fn ->
                 Store.claim_next(store, "skip-locked-owner", @lease_ms)
               end)

      refute claimant_backend_pid == holder.backend_pid

      assert :ok = Store.release(store, lease)
    after
      release_row_holder(holder)
    end
  end

  @tag mcp_contract: ["tasks-postgres-live-concurrency"]
  test "concurrent terminal compare-and-set permits one immutable winner", %{store: store} do
    task_id = unique_id("terminal-cas")
    initial = create_task!(store, task_id)
    assert {:ok, ^initial, lease} = Store.claim(store, task_id, "terminal-owner", @lease_ms)

    completed = event!(Event.completed(%{"winner" => "completed"}, id: unique_id("complete")))
    failed = event!(Event.failed(error("failed"), "failed", id: unique_id("failed")))

    results =
      race([
        fn -> Store.transition(store, task_id, 0, completed, {:worker, lease}) end,
        fn -> Store.transition(store, task_id, 0, failed, {:worker, lease}) end
      ])

    assert Enum.count(
             results,
             &match?({:ok, %Transition{outcome: :applied}}, &1)
           ) == 1

    assert Enum.count(results, &match?({:conflict, %Snapshot{}}, &1)) == 1

    terminal = scoped_snapshot!(store, task_id)
    assert terminal.revision == 1
    assert terminal.task.status in [:completed, :failed]
    assert :ok = Store.release(store, lease)
  end

  @tag mcp_contract: ["tasks-postgres-live-ledger"]
  test "identical events replay once and changed ID reuse rolls back", %{
    schema: schema,
    store: store
  } do
    task_id = unique_id("event-replay")
    initial = create_task!(store, task_id)
    assert {:ok, ^initial, lease} = Store.claim(store, task_id, "ledger-owner", @lease_ms)

    event_id = unique_id("stable-event")
    completed = event!(Event.completed(%{"value" => 1}, id: event_id))

    results =
      race([
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

    assert 1 == event_count(schema, task_id)
    assert %Snapshot{revision: 1, task: %{status: :completed}} = scoped_snapshot!(store, task_id)
    assert :ok = Store.release(store, lease)
  end

  @tag mcp_contract: ["tasks-postgres-live-ledger"]
  test "an event revision conflict rolls back the preceding aggregate update", %{
    schema: schema,
    store: store
  } do
    task_id = unique_id("event-rollback")
    initial = create_task!(store, task_id)
    assert {:ok, ^initial, lease} = Store.claim(store, task_id, "rollback-owner", @lease_ms)

    conflicting_event =
      event!(Event.completed(%{"seeded" => true}, id: unique_id("conflicting-event")))

    assert {:ok, encoded_effects} = Persistence.encode_effects(%{})

    assert {1, nil} =
             LiveRepo.insert_all(
               EventRow,
               [
                 %{
                   task_id: task_id,
                   event_id: conflicting_event.id,
                   row_format: Persistence.row_format(),
                   event: Event.to_map(conflicting_event),
                   event_kind: "completed",
                   event_revision: 1,
                   committed_at: database_now(),
                   effects: encoded_effects
                 }
               ],
               prefix: schema
             )

    attempted = event!(Event.completed(%{"attempted" => true}, id: unique_id("attempted")))

    assert {:error, _constraint_failure} =
             Store.transition(store, task_id, 0, attempted, {:worker, lease})

    persisted_row = row!(schema, task_id)
    assert persisted_row.revision == 0
    assert persisted_row.status == "working"
    assert {:ok, ^initial} = Persistence.decode_task_row(persisted_row)
    assert event_count(schema, task_id) == 1
    assert :ok = Store.release(store, lease)
  end

  @tag mcp_contract: ["tasks-postgres-live-leases"]
  test "renewal replaces exact expiry and makes the previous lease stale", %{store: store} do
    task_id = unique_id("renew")
    initial = create_task!(store, task_id)
    assert {:ok, ^initial, lease} = Store.claim(store, task_id, "renew-owner", 2_000)
    assert {:ok, renewed} = Store.renew(store, lease, 20_000)
    refute DateTime.compare(renewed.expires_at, lease.expires_at) == :eq

    assert {:error, :stale_lease} = Store.worker_snapshot(store, task_id, lease)
    assert {:error, :stale_lease} = Store.release(store, lease)
    assert {:ok, ^initial} = Store.worker_snapshot(store, task_id, renewed)
    assert :ok = Store.release(store, renewed)
  end

  @tag mcp_contract: ["tasks-postgres-live-leases"]
  test "database-expired claims increment generation and fence the prior worker", %{
    schema: schema,
    store: store
  } do
    task_id = unique_id("expired")
    initial = create_task!(store, task_id)
    assert {:ok, ^initial, first} = Store.claim(store, task_id, "first-owner", @lease_ms)

    backdate_claim!(schema, task_id)

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

  @tag mcp_contract: ["tasks-postgres-live-time"]
  test "timestamptz queues, retries, and TTLs remain exact in a non-UTC session",
       %{
         schema: schema,
         store: store
       } do
    assert [[@session_timezone]] = query!("SHOW TIME ZONE").rows
    assert_temporal_columns_are_timestamptz!(schema)

    retry_task_id = unique_id("timezone-retry")

    retry_work =
      Work.new!(retry_task_id, "postgres/timezone-retry", %{},
        retry_policy: RetryPolicy.new!([@timezone_retry_delay_ms])
      )

    retry_initial = create_task!(store, retry_task_id, "tenant-a", work: retry_work)

    assert {:ok, ^retry_initial, retry_lease} =
             Store.claim(store, retry_task_id, "timezone-retry-owner", @lease_ms)

    retry_event =
      event!(Event.retry_requested(error("timezone retry"), "retry", id: unique_id("retry")))

    assert {:ok, %Transition{snapshot: scheduled}} =
             Store.transition(store, retry_task_id, 0, retry_event, {:worker, retry_lease})

    retry_row = row!(schema, retry_task_id)

    Enum.each(
      [
        retry_row.created_at,
        retry_row.retry_at,
        retry_row.claim_expires_at,
        retry_row.inserted_at,
        retry_row.updated_at
      ],
      &assert_utc_datetime_usec!/1
    )

    assert [[event_committed_at]] =
             query!(
               "SELECT committed_at FROM #{qualified(schema, "mcp_task_events")} " <>
                 "WHERE task_id = $1 AND event_id = $2",
               [retry_task_id, retry_event.id]
             ).rows

    assert_utc_datetime_usec!(event_committed_at)

    assert :ok = Store.release(store, retry_lease)

    assert {:deferred, retry_remaining_ms} =
             Store.claim(store, retry_task_id, "timezone-early-owner", @lease_ms)

    assert retry_remaining_ms > 0
    assert retry_remaining_ms <= @timezone_retry_delay_ms

    queue_task_id = unique_id("timezone-queue")
    queue_initial = create_task!(store, queue_task_id)

    assert {:ok, ^queue_initial, queue_lease} =
             Store.claim_next(store, "timezone-queue-owner", @lease_ms)

    assert queue_initial.task.id == queue_task_id

    assert :ok = Store.release(store, queue_lease)

    ttl_task_id = unique_id("timezone-ttl")
    _ttl_snapshot = create_task!(store, ttl_task_id, "tenant-a", ttl_ms: @timezone_ttl_ms)
    ttl_row = row!(schema, ttl_task_id)
    ttl_expires_at = ttl_row.expires_at

    Enum.each(
      [ttl_row.created_at, ttl_row.expires_at, ttl_row.inserted_at, ttl_row.updated_at],
      &assert_utc_datetime_usec!/1
    )

    assert [[installed_at]] =
             query!("SELECT installed_at FROM #{qualified(schema, "mcp_task_store_metadata")}").rows

    assert_utc_datetime_usec!(installed_at)

    assert DateTime.compare(database_now(), ttl_expires_at) == :lt
    assert {:ok, []} = Store.reap(store)
    assert table_count(schema, "mcp_tasks", ttl_task_id) == 1

    wait_until_database_time!(scheduled.retry_at)

    assert {:ok, %Snapshot{task: %{id: ^retry_task_id}}, due_retry_lease} =
             Store.claim(store, retry_task_id, "timezone-due-owner", @lease_ms)

    assert :ok = Store.release(store, due_retry_lease)
    assert DateTime.compare(database_now(), ttl_expires_at) == :lt
    assert {:ok, []} = Store.reap(store)

    wait_until_database_time!(DateTime.to_iso8601(ttl_expires_at))

    assert {:ok, [^ttl_task_id]} = Store.reap(store)
    assert table_count(schema, "mcp_tasks", ttl_task_id) == 0
  end

  @tag mcp_contract: ["tasks-postgres-live-time"]
  test "retry claim waits on a row lock, crosses the database due time, and then succeeds",
       %{
         config: config,
         schema: schema,
         store: store
       } do
    task_id = unique_id("retry")

    work =
      Work.new!(task_id, "postgres/retry", %{}, retry_policy: RetryPolicy.new!([@retry_delay_ms]))

    initial = create_task!(store, task_id, "tenant-a", work: work)
    assert {:ok, ^initial, lease} = Store.claim(store, task_id, "retry-owner", @lease_ms)

    retry = event!(Event.retry_requested(error("temporary"), "retry", id: unique_id("retry")))
    before_commit = database_now()

    assert {:ok, %Transition{snapshot: scheduled} = transition} =
             Store.transition(store, task_id, 0, retry, {:worker, lease})

    after_commit = database_now()
    committed_at = timestamp!(transition.committed_at)
    retry_at = timestamp!(scheduled.retry_at)

    assert scheduled.retry_count == 1
    assert transition.effects.retry.delay_ms == @retry_delay_ms
    assert transition.effects.retry.retry_at == scheduled.retry_at
    assert DateTime.diff(retry_at, committed_at, :millisecond) == @retry_delay_ms
    assert between?(committed_at, before_commit, after_commit)
    assert :ok = Store.release(store, lease)
    assert {:deferred, remaining_ms} = Store.claim(store, task_id, "early-owner", @lease_ms)
    assert remaining_ms > 0
    assert remaining_ms <= @retry_delay_ms

    holder = hold_row!(schema, task_id)
    claimant = blocked_exact_claim(store, task_id)

    try do
      assert_receive {:postgres_claim_ready, claimant_backend_pid}, 2_000
      refute claimant_backend_pid == holder.backend_pid
      send(claimant.pid, :run_postgres_claim)
      await_blocked!(claimant_backend_pid, holder.backend_pid)
      assert DateTime.compare(database_now(), retry_at) == :lt
      wait_until_database_time!(scheduled.retry_at)
      release_row_holder(holder)

      assert {:ok, %Snapshot{retry_count: 1}, due_lease} = Task.await(claimant, 5_000)

      assert {:ok, %{checked: 1, errors: []}} = Postgres.audit(config, limit: 10)
      assert :ok = Store.release(store, due_lease)
    after
      release_row_holder(holder)
      shutdown_task(claimant)
    end
  end

  @tag mcp_contract: ["tasks-postgres-live-time"]
  test "TTL reaping deletes the aggregate and cascades its event ledger", %{
    schema: schema,
    store: store
  } do
    task_id = unique_id("ttl")
    created_at = database_now() |> DateTime.add(-2, :second) |> DateTime.to_iso8601()
    initial = create_task!(store, task_id, "tenant-a", created_at: created_at, ttl_ms: 1)
    assert {:ok, ^initial, lease} = Store.claim(store, task_id, "ttl-owner", @lease_ms)

    completed = event!(Event.completed(%{"expired" => true}, id: unique_id("ttl-event")))

    assert {:ok, %Transition{outcome: :applied}} =
             Store.transition(store, task_id, 0, completed, {:worker, lease})

    assert :ok = Store.release(store, lease)
    assert event_count(schema, task_id) == 1
    assert {:ok, [^task_id]} = Store.reap(store)
    assert table_count(schema, "mcp_tasks", task_id) == 0
    assert event_count(schema, task_id) == 0
  end

  @tag mcp_contract: ["tasks-postgres-live-recovery"]
  @tag capture_log: true
  test "a second Runner recovers a hard-dead first Runner without changing Work or retry count",
       %{
         schema: schema,
         store: store
       } do
    task_id = unique_id("runner-recovery")

    work =
      Work.new!(task_id, "postgres/recovery", %{"mode" => "hard-death"},
        retry_policy: RetryPolicy.new!([0])
      )

    initial = create_task!(store, task_id, "tenant-a", work: work)
    assert {:ok, ^initial, seed_lease} = Store.claim(store, task_id, "seed-owner", @lease_ms)

    retry = event!(Event.retry_requested(error("seed"), "seed retry", id: unique_id("seed")))

    assert {:ok, %Transition{snapshot: seeded}} =
             Store.transition(store, task_id, 0, retry, {:worker, seed_lease})

    assert seeded.retry_count == 1
    assert :ok = Store.release(store, seed_lease)
    make_retry_due!(schema, task_id)

    counter = start_supervised!({Agent, fn -> 0 end})
    executor = {LiveExecutor, %{counter: counter, owner: self()}}
    first_runner = start_runner!(store, executor, "runner-one")
    on_exit(fn -> stop_runner(first_runner) end)

    assert_receive {:postgres_live_execution, ^task_id, 1, first_work, first_worker}, 2_000
    assert first_work == work

    claimed_before_kill = row!(schema, task_id)
    assert claimed_before_kill.claim_owner == "runner-one"
    assert claimed_before_kill.lease_generation == 2
    refute is_nil(claimed_before_kill.claim_token)
    assert DateTime.compare(claimed_before_kill.claim_expires_at, database_now()) == :gt

    runner_monitor = Process.monitor(first_runner)
    worker_monitor = Process.monitor(first_worker)
    Process.exit(first_runner, :kill)
    assert_receive {:DOWN, ^runner_monitor, :process, ^first_runner, :killed}, 2_000
    assert_receive {:DOWN, ^worker_monitor, :process, ^first_worker, _reason}, 2_000

    persisted_after_kill = row!(schema, task_id)

    assert claim_identity(persisted_after_kill) == claim_identity(claimed_before_kill)
    assert persisted_after_kill.claim_expires_at == claimed_before_kill.claim_expires_at
    assert DateTime.compare(persisted_after_kill.claim_expires_at, database_now()) == :gt

    backdate_claim!(schema, task_id)
    expired_claim = row!(schema, task_id)
    assert claim_identity(expired_claim) == claim_identity(claimed_before_kill)
    assert DateTime.compare(expired_claim.claim_expires_at, database_now()) == :lt

    second_runner = start_runner!(store, executor, "runner-two")
    on_exit(fn -> stop_runner(second_runner) end)

    assert_receive {:postgres_live_execution, ^task_id, 2, second_work, _worker}, 2_000
    assert second_work == work

    completed = eventually_snapshot!(store, task_id, &(&1.task.status == :completed))
    assert completed.work == work
    assert completed.retry_count == 1
    assert completed.task.result["idempotencyKey"] == task_id
    assert Agent.get(counter, & &1) == 2

    final_row = eventually_row!(schema, task_id, &is_nil(&1.claim_owner))
    assert final_row.lease_generation == 3

    access = authorize!(store, context("tenant-a"), {:get, task_id})
    assert {:ok, history} = Postgres.history(elem(store, 1), task_id, access)
    assert Enum.map(history, & &1.event.kind) == [:retry_requested, :completed]
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
    created_at =
      Keyword.get_lazy(opts, :created_at, fn -> database_now() |> DateTime.to_iso8601() end)

    ttl_ms = Keyword.get(opts, :ttl_ms)

    task =
      ProtocolTask.new!(
        id: task_id,
        created_at: created_at,
        ttl_ms: ttl_ms,
        poll_interval_ms: 10,
        status_message: "accepted"
      )

    work = Keyword.get_lazy(opts, :work, fn -> Work.new!(task_id, "postgres/test", %{}) end)
    access = authorize!(store, context(tenant), {:create, task_id})
    assert {:ok, snapshot} = Store.create(store, task, work, access)
    snapshot
  end

  defp scoped_snapshot!(store, task_id, tenant \\ "tenant-a") do
    access = authorize!(store, context(tenant), {:get, task_id})
    assert {:ok, snapshot} = Store.get(store, task_id, access)
    snapshot
  end

  defp eventually_snapshot!(store, task_id, predicate) do
    deadline = System.monotonic_time(:millisecond) + 3_000
    eventually_snapshot(store, task_id, predicate, deadline)
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

  defp eventually_row!(schema, task_id, predicate) do
    deadline = System.monotonic_time(:millisecond) + 3_000
    eventually_row(schema, task_id, predicate, deadline)
  end

  defp eventually_row(schema, task_id, predicate, deadline) do
    row = row!(schema, task_id)

    cond do
      predicate.(row) ->
        row

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("row did not reach expected state")

      true ->
        Process.sleep(10)
        eventually_row(schema, task_id, predicate, deadline)
    end
  end

  defp race(functions) do
    gate = make_ref()
    parent = self()

    tasks = Enum.map(functions, &start_racer(&1, parent, gate))

    ready =
      Enum.map(tasks, fn _task ->
        assert_receive {:postgres_race_ready, ^gate, process, backend_pid}, 2_000
        {process, backend_pid}
      end)

    assert ready |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> length() == length(ready)

    Enum.each(ready, fn {process, _backend_pid} ->
      send(process, {:run_postgres_race, gate})
    end)

    Enum.map(tasks, &Task.await(&1, 5_000))
  end

  defp start_racer(function, parent, gate) do
    Task.async(fn -> checked_out_racer(function, parent, gate) end)
  end

  defp checked_out_racer(function, parent, gate) do
    LiveRepo.checkout(fn ->
      send(parent, {:postgres_race_ready, gate, self(), backend_pid()})
      await_race_start(function, gate)
    end)
  end

  defp await_race_start(function, gate) do
    receive do
      {:run_postgres_race, ^gate} -> function.()
    end
  end

  defp hold_row!(schema, task_id) do
    gate = make_ref()
    parent = self()

    task = Task.async(fn -> checked_out_row_holder(schema, task_id, parent, gate) end)

    assert_receive {:postgres_row_locked, ^gate, backend_pid}, 2_000
    %{task: task, gate: gate, backend_pid: backend_pid}
  end

  defp checked_out_row_holder(schema, task_id, parent, gate) do
    LiveRepo.checkout(fn ->
      transact_row_holder(schema, task_id, parent, gate, backend_pid())
    end)
  end

  defp transact_row_holder(schema, task_id, parent, gate, backend_pid) do
    LiveRepo.transact(fn ->
      query!(
        "SELECT task_id FROM #{qualified(schema, "mcp_tasks")} " <>
          "WHERE task_id = $1 FOR UPDATE",
        [task_id]
      )

      send(parent, {:postgres_row_locked, gate, backend_pid})
      await_row_release(gate)
    end)
  end

  defp await_row_release(gate) do
    receive do
      {:release_postgres_row, ^gate} -> {:ok, :ok}
    after
      5_000 -> raise "timed out waiting to release PostgreSQL row lock"
    end
  end

  defp release_row_holder(%{task: %Task{pid: pid} = task, gate: gate}) do
    if Process.alive?(pid) do
      send(pid, {:release_postgres_row, gate})
      assert {:ok, :ok} = Task.await(task, 2_000)
    end

    :ok
  end

  defp blocked_exact_claim(store, task_id) do
    parent = self()
    Task.async(fn -> checked_out_blocked_claim(store, task_id, parent) end)
  end

  defp checked_out_blocked_claim(store, task_id, parent) do
    LiveRepo.checkout(fn ->
      send(parent, {:postgres_claim_ready, backend_pid()})
      await_claim_start(store, task_id)
    end)
  end

  defp await_claim_start(store, task_id) do
    receive do
      :run_postgres_claim -> Store.claim(store, task_id, "due-owner", @lease_ms)
    after
      5_000 -> raise "timed out waiting to run blocked PostgreSQL claim"
    end
  end

  defp await_blocked!(claimant_backend_pid, holder_backend_pid, attempts \\ 200)

  defp await_blocked!(_claimant_backend_pid, _holder_backend_pid, 0) do
    flunk("claim transaction never blocked behind the held PostgreSQL row")
  end

  defp await_blocked!(claimant_backend_pid, holder_backend_pid, attempts) do
    assert [[blocking_pids]] =
             query!("SELECT pg_blocking_pids($1)", [claimant_backend_pid]).rows

    if holder_backend_pid in blocking_pids do
      :ok
    else
      Process.sleep(10)
      await_blocked!(claimant_backend_pid, holder_backend_pid, attempts - 1)
    end
  end

  defp wait_until_database_time!(timestamp) do
    assert [[_sleep_result]] =
             query!(
               "SELECT pg_sleep(" <>
                 "GREATEST(EXTRACT(EPOCH FROM ($1::timestamptz - clock_timestamp())), 0)" <>
                 "::double precision)",
               [timestamp!(timestamp)]
             ).rows

    assert DateTime.compare(database_now(), timestamp!(timestamp)) in [:eq, :gt]
  end

  defp checked_out(function) do
    LiveRepo.checkout(fn -> {backend_pid(), function.()} end)
  end

  defp backend_pid do
    assert [[backend_pid]] = query!("SELECT pg_backend_pid()").rows
    backend_pid
  end

  defp shutdown_task(%Task{pid: pid} = task) do
    if Process.alive?(pid), do: Task.shutdown(task, :brutal_kill)
    :ok
  end

  defp stop_runner(runner) do
    if Process.alive?(runner), do: GenServer.stop(runner, :normal, 2_000)
    :ok
  end

  defp claim_identity(row) do
    Map.take(row, [:claim_owner, :claim_token, :lease_generation])
  end

  defp between?(datetime, lower, upper) do
    DateTime.compare(datetime, lower) in [:eq, :gt] and
      DateTime.compare(datetime, upper) in [:eq, :lt]
  end

  defp timestamp!(timestamp) do
    assert {:ok, datetime, 0} = DateTime.from_iso8601(timestamp)
    datetime
  end

  defp make_retry_due!(schema, task_id) do
    row = row!(schema, task_id)
    assert {:ok, snapshot} = Persistence.decode_task_row(row)
    due_at = database_now() |> DateTime.add(-1, :millisecond)
    updated_snapshot = %{snapshot | retry_at: DateTime.to_iso8601(due_at)}
    assert {:ok, projected} = Persistence.project_snapshot(updated_snapshot)

    query = from task in TaskRow, where: task.task_id == ^task_id

    assert {1, nil} =
             LiveRepo.update_all(
               query,
               [
                 set: [
                   snapshot: projected.snapshot,
                   snapshot_format: projected.snapshot_format,
                   retry_at: projected.retry_at
                 ]
               ],
               prefix: schema
             )
  end

  defp backdate_claim!(schema, task_id) do
    query!(
      "UPDATE #{qualified(schema, "mcp_tasks")} " <>
        "SET claim_expires_at = clock_timestamp() - INTERVAL '1 second' " <>
        "WHERE task_id = $1",
      [task_id]
    )
  end

  defp row!(schema, task_id) do
    query = from task in TaskRow, where: task.task_id == ^task_id
    LiveRepo.one!(query, prefix: schema)
  end

  defp event_count(schema, task_id),
    do: table_count(schema, "mcp_task_events", task_id)

  defp table_count(schema, table, task_id) do
    assert [[count]] =
             query!("SELECT count(*) FROM #{qualified(schema, table)} WHERE task_id = $1", [
               task_id
             ]).rows

    count
  end

  defp database_now do
    assert [[%DateTime{} = now]] = query!("SELECT clock_timestamp()").rows
    now
  end

  defp assert_temporal_columns_are_timestamptz!(schema) do
    expected =
      MapSet.new([
        {"mcp_task_store_metadata", "installed_at"},
        {"mcp_tasks", "created_at"},
        {"mcp_tasks", "expires_at"},
        {"mcp_tasks", "retry_at"},
        {"mcp_tasks", "claim_expires_at"},
        {"mcp_tasks", "inserted_at"},
        {"mcp_tasks", "updated_at"},
        {"mcp_task_events", "committed_at"}
      ])

    assert %{rows: rows} =
             query!(
               "SELECT table_name, column_name, data_type, udt_name, datetime_precision " <>
                 "FROM information_schema.columns " <>
                 "WHERE table_schema = $1 " <>
                 "AND table_name IN " <>
                 "('mcp_task_store_metadata', 'mcp_tasks', 'mcp_task_events') " <>
                 "AND data_type LIKE 'timestamp%'",
               [schema]
             )

    observed =
      MapSet.new(rows, fn [table, column, data_type, udt_name, precision] ->
        assert data_type == "timestamp with time zone"
        assert udt_name == "timestamptz"
        assert precision == 6
        {table, column}
      end)

    assert observed == expected
  end

  defp assert_utc_datetime_usec!(datetime) do
    assert %DateTime{
             time_zone: "Etc/UTC",
             utc_offset: 0,
             std_offset: 0,
             microsecond: {_microsecond, 6}
           } = datetime
  end

  defp migrate_up!(schema) do
    migrate_up!(schema, @migration_version, Migration)
  end

  defp migrate_up!(schema, version, module) do
    case Ecto.Migrator.up(
           LiveRepo,
           version,
           module,
           prefix: schema,
           log: false
         ) do
      :ok -> :ok
      :already_up -> :ok
    end
  end

  defp migrate_down!(schema) do
    migrate_down!(schema, @migration_version, Migration)
  end

  defp migrate_down!(schema, version, module) do
    case Ecto.Migrator.down(
           LiveRepo,
           version,
           module,
           prefix: schema,
           log: false
         ) do
      :ok -> :ok
      :already_down -> :ok
    end
  end

  defp migration_index_count(schema) do
    query!(
      "SELECT count(*) FROM pg_indexes WHERE schemaname = $1 AND indexname = $2",
      [schema, "mcp_task_events_committed"]
    ).rows
  end

  defp create_schema!(schema), do: query!("CREATE SCHEMA #{quote_identifier(schema)}")

  defp drop_schema!(schema),
    do: query!("DROP SCHEMA IF EXISTS #{quote_identifier(schema)} CASCADE")

  defp query!(sql, params \\ []), do: Ecto.Adapters.SQL.query!(LiveRepo, sql, params)

  defp qualified(schema, table),
    do: quote_identifier(schema) <> "." <> quote_identifier(table)

  defp quote_identifier(identifier),
    do: "\"" <> String.replace(identifier, "\"", "\"\"") <> "\""

  defp unique_schema(label),
    do: "mcp_tasks_#{label}_#{System.unique_integer([:positive, :monotonic])}"

  defp unique_id(label),
    do: label <> "-" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))

  defp authorize(store, context, action), do: Store.authorize(store, context, action)

  defp authorize!(store, context, action) do
    assert {:ok, access} = authorize(store, context, action)
    access
  end

  defp event!({:ok, %Event{} = event}), do: event

  defp error(message),
    do: %{"code" => -32_603, "message" => message}

  defp context(tenant) do
    %Context{
      protocol_version: V2026_07_28.version(),
      protocol: V2026_07_28,
      transport: %TransportContext{transport: :direct},
      auth: %{"tenant" => tenant}
    }
  end
end
