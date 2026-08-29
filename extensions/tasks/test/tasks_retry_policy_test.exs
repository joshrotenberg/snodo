defmodule MCPEx.TasksRetryPolicyTest.Executor do
  @moduledoc false

  @behaviour MCP.Extensions.Tasks.WorkExecutor

  alias MCP.Extensions.Tasks.Runner

  @impl true
  def execute(work, cancellation, state) do
    attempt = Agent.get_and_update(state.counter, &{&1 + 1, &1 + 1})
    send(state.owner, {:retry_execution, work.idempotency_key, attempt, work})
    execute_mode(work.input["mode"], work, cancellation, state, attempt)
  end

  defp execute_mode("retry_once", work, _cancellation, _state, attempt) do
    if attempt == 1, do: retry_outcome(attempt), else: completed_outcome(work, attempt)
  end

  defp execute_mode("always_retry", _work, _cancellation, _state, attempt),
    do: retry_outcome(attempt)

  defp execute_mode("input_retry", work, cancellation, state, attempt) do
    response =
      Runner.await_input(
        state.runner,
        work.idempotency_key,
        work.input["key"],
        work.input["request"],
        cancellation
      )

    send(state.owner, {:retry_input, attempt, response})

    case response do
      {:ok, _accepted} when attempt == 1 -> retry_outcome(attempt)
      {:ok, accepted} -> completed_outcome(work, attempt, accepted)
      {:error, reason} -> raise "input failed: #{inspect(reason)}"
    end
  end

  defp execute_mode("raise", _work, _cancellation, _state, _attempt),
    do: raise("executor raised")

  defp execute_mode("invalid", _work, _cancellation, _state, _attempt), do: :invalid

  defp execute_mode("failed", _work, _cancellation, _state, attempt) do
    {:failed,
     %{"code" => -32_603, "message" => "terminal failure", "data" => %{"attempt" => attempt}},
     "Terminal failure"}
  end

  defp retry_outcome(attempt) do
    {:retry,
     %{
       "code" => -32_603,
       "message" => "temporary failure",
       "data" => %{"attempt" => attempt}
     }, "Retry requested"}
  end

  defp completed_outcome(work, attempt, input \\ nil) do
    {:completed,
     %{
       "ok" => true,
       "attempt" => attempt,
       "idempotencyKey" => work.idempotency_key,
       "input" => input
     }}
  end
end

defmodule MCPEx.TasksRetryPolicyTest.FaultStore do
  @moduledoc false

  @behaviour MCP.Extensions.Tasks.Store

  alias MCP.Extensions.Tasks.Store.Memory
  alias MCP.Extensions.Tasks.Transition

  @impl true
  def authorize(state, context, action), do: Memory.authorize(state.store, context, action)

  @impl true
  def create(state, task, work, access), do: Memory.create(state.store, task, work, access)

  @impl true
  def get(state, task_id, access), do: Memory.get(state.store, task_id, access)

  @impl true
  def worker_snapshot(state, task_id, lease),
    do: Memory.worker_snapshot(state.store, task_id, lease)

  @impl true
  def claim(state, task_id, owner_id, lease_ms),
    do: Memory.claim(state.store, task_id, owner_id, lease_ms)

  @impl true
  def claim_next(state, owner_id, lease_ms),
    do: Memory.claim_next(state.store, owner_id, lease_ms)

  @impl true
  def renew(state, lease, lease_ms), do: Memory.renew(state.store, lease, lease_ms)

  @impl true
  def release(state, lease) do
    if consume_fault(state.faults, :release) do
      {:error, :transient_release_failure}
    else
      Memory.release(state.store, lease)
    end
  end

  @impl true
  def reap(state), do: Memory.reap(state.store)

  @impl true
  def transition(state, task_id, revision, event, authority) do
    if event.kind == :retry_requested and consume_fault(state.faults, :duplicate_retry) do
      commit_then_report_conflict(state, task_id, revision, event, authority)
    else
      Memory.transition(state.store, task_id, revision, event, authority)
    end
  end

  defp commit_then_report_conflict(state, task_id, revision, event, authority) do
    case Memory.transition(state.store, task_id, revision, event, authority) do
      {:ok,
       %Transition{
         snapshot: snapshot,
         effects: %{retry: %{retry_at: retry_at}}
       }} ->
        Agent.update(state.clock, fn _current -> retry_at end)
        {:conflict, snapshot}

      other ->
        other
    end
  end

  defp consume_fault(faults, key) do
    Agent.get_and_update(faults, fn configured ->
      case Map.get(configured, key, 0) do
        remaining when remaining > 0 ->
          {true, Map.put(configured, key, remaining - 1)}

        _none ->
          {false, configured}
      end
    end)
  end
end

defmodule MCP.TasksRetryPolicyTest do
  use ExUnit.Case, async: false

  @moduletag mcp_contract: ["tasks-retry-policy"]
  @moduletag :tasks_package

  alias MCP.Context
  alias MCP.Extensions.Tasks.Event
  alias MCP.Extensions.Tasks.RetryPolicy
  alias MCP.Extensions.Tasks.Runner
  alias MCP.Extensions.Tasks.Snapshot
  alias MCP.Extensions.Tasks.Store
  alias MCP.Extensions.Tasks.Store.Dets
  alias MCP.Extensions.Tasks.Store.Memory
  alias MCP.Extensions.Tasks.Task, as: ProtocolTask
  alias MCP.Extensions.Tasks.Transition
  alias MCP.Extensions.Tasks.Work
  alias MCP.Protocol.V2026_07_28
  alias MCP.Transport.Context, as: TransportContext
  alias MCPEx.TasksRetryPolicyTest.Executor
  alias MCPEx.TasksRetryPolicyTest.FaultStore

  @created_at "2026-08-24T10:00:00.000Z"
  @retry_delay_ms 60_000
  @lease_ms 120_000
  @runner_name MCP.TasksRetryPolicyTest.Runner

  test "retry policies persist exact fixed and expanded exponential delays" do
    assert RetryPolicy.none() == RetryPolicy.new!([])
    assert RetryPolicy.fixed!(250, 3).delays_ms == [250, 250, 250]

    assert RetryPolicy.exponential!(100, 5, max_delay_ms: 450).delays_ms == [
             100,
             200,
             400,
             450,
             450
           ]

    policy = RetryPolicy.new!([0, 250, 1_000])
    assert {:ok, 0} = RetryPolicy.next_delay(policy, 0)
    assert {:ok, 1_000} = RetryPolicy.next_delay(policy, 2)
    assert :exhausted = RetryPolicy.next_delay(policy, 3)

    encoded = RetryPolicy.to_map(policy)
    assert {:ok, ^policy} = encoded |> JSON.encode!() |> JSON.decode!() |> RetryPolicy.from_map()

    assert {:error, :invalid_retry_delays} = RetryPolicy.new([-1])
    assert {:error, :invalid_retry_delays} = RetryPolicy.new([4_294_967_296])

    assert {:error, :initial_delay_exceeds_maximum} =
             RetryPolicy.exponential(500, 2, max_delay_ms: 499)
  end

  test "retry_requested schedules from commit time and atomically fails when exhausted" do
    work = retry_work("pure-retry", [250, 1_000], "always_retry")
    initial = Snapshot.new(task("pure-retry"), work)
    first_error = retry_error(1)
    first_event = event!(Event.retry_requested(first_error, "first", id: "retry-one"))

    assert {:ok, %Transition{} = first} =
             Transition.apply(initial, first_event, "2026-08-24T10:00:01.000Z")

    assert first.outcome == :applied
    assert first.snapshot.task.status == :working
    assert first.snapshot.retry_count == 1
    assert first.snapshot.retry_at == "2026-08-24T10:00:01.250Z"

    assert first.snapshot.last_failure == %{
             "error" => first_error,
             "statusMessage" => "first"
           }

    assert first.effects.retry == %{
             disposition: :scheduled,
             retry_at: "2026-08-24T10:00:01.250Z",
             delay_ms: 250,
             retry_count: 1
           }

    assert {:ok, ^first_event} =
             first_event |> Event.to_map() |> JSON.encode!() |> JSON.decode!() |> Event.from_map()

    second_event = event!(Event.retry_requested(retry_error(2), "second", id: "retry-two"))

    assert {:ok, %Transition{} = second} =
             Transition.apply(first.snapshot, second_event, "2026-08-24T10:00:02.000Z")

    assert second.snapshot.retry_count == 2
    assert second.snapshot.retry_at == "2026-08-24T10:00:03.000Z"

    exhausted_error = retry_error(3)

    exhausted_event =
      event!(Event.retry_requested(exhausted_error, "exhausted", id: "retry-three"))

    assert {:ok, %Transition{} = exhausted} =
             Transition.apply(
               second.snapshot,
               exhausted_event,
               "2026-08-24T10:00:04.000Z"
             )

    assert exhausted.snapshot.task.status == :failed
    assert exhausted.snapshot.task.error == exhausted_error
    assert exhausted.snapshot.retry_count == 2
    assert exhausted.snapshot.retry_at == nil

    assert exhausted.snapshot.last_failure == %{
             "error" => exhausted_error,
             "statusMessage" => "exhausted"
           }

    assert exhausted.effects.retry == %{
             disposition: :exhausted,
             retry_at: nil,
             delay_ms: nil,
             retry_count: 2
           }

    assert :ok = Snapshot.validate(exhausted.snapshot)
  end

  test "Memory excludes a scheduled retry until store time reaches the exact boundary" do
    %{clock: clock, store: store, store_ref: store_ref} = memory_store()
    task_id = "memory-retry-boundary"
    snapshot = create_unclaimed!(store_ref, task_id, retry_work(task_id, [@retry_delay_ms]))
    assert {:ok, ^snapshot, lease} = Store.claim(store_ref, task_id, "first", @lease_ms)

    retry_event =
      event!(Event.retry_requested(retry_error(1), "temporary", id: "stable-retry"))

    assert {:ok, %Transition{} = scheduled} =
             Store.transition(
               store_ref,
               task_id,
               snapshot.revision,
               retry_event,
               {:worker, lease}
             )

    assert scheduled.snapshot.retry_at == "2026-08-24T10:01:00.001Z"
    assert :ok = Store.release(store_ref, lease)

    advance_clock(clock, @retry_delay_ms)
    assert {:deferred, 1} = Store.claim(store_ref, task_id, "early", @lease_ms)
    assert :empty = Store.claim_next(store_ref, "early", @lease_ms)

    advance_clock(clock, 1)
    assert {:ok, due, due_lease} = Store.claim(store_ref, task_id, "due", @lease_ms)
    assert due.retry_count == 1
    assert due.work.idempotency_key == task_id

    assert {:ok, %Transition{} = duplicate} =
             Store.transition(
               store_ref,
               task_id,
               snapshot.revision,
               retry_event,
               {:worker, due_lease}
             )

    assert duplicate.outcome == :duplicate
    assert duplicate.effects == scheduled.effects
    assert duplicate.event_revision == scheduled.event_revision

    access = authorize!(store_ref, {:get, task_id})

    assert {:ok, [%{event: %{kind: :retry_requested}}]} =
             Memory.history(store, task_id, access)
  end

  test "DETS reopen preserves retry availability and identical-event effects" do
    clock = start_supervised!({Agent, fn -> @created_at end}, id: {Agent, make_ref()})
    path = temporary_dets_path()

    {:ok, server} =
      Dets.start_link(
        path: path,
        table: :mcp_tasks_retry_policy,
        clock: fn -> Agent.get(clock, & &1) end
      )

    store_ref = {Dets, server}
    task_id = "dets-retry-reopen"
    snapshot = create_unclaimed!(store_ref, task_id, retry_work(task_id, [@retry_delay_ms]))
    assert {:ok, ^snapshot, lease} = Store.claim(store_ref, task_id, "before-reopen", @lease_ms)

    event = event!(Event.retry_requested(retry_error(1), "temporary", id: "dets-retry"))

    assert {:ok, %Transition{} = scheduled} =
             Store.transition(
               store_ref,
               task_id,
               snapshot.revision,
               event,
               {:worker, lease}
             )

    assert scheduled.effects.retry.disposition == :scheduled
    GenServer.stop(server)

    {:ok, reopened} =
      Dets.start_link(
        path: path,
        table: :mcp_tasks_retry_policy,
        clock: fn -> Agent.get(clock, & &1) end
      )

    reopened_ref = {Dets, reopened}
    recovered = snapshot!(reopened_ref, task_id)
    assert recovered.retry_count == 1
    assert recovered.retry_at == scheduled.snapshot.retry_at
    assert recovered.last_failure == scheduled.snapshot.last_failure

    assert {:deferred, 60_001} =
             Store.claim(reopened_ref, task_id, "too-early", @lease_ms)

    advance_clock(clock, @retry_delay_ms + 1)

    assert {:ok, ^recovered, due_lease} =
             Store.claim(reopened_ref, task_id, "after-reopen", @lease_ms)

    assert {:ok, %Transition{} = duplicate} =
             Store.transition(
               reopened_ref,
               task_id,
               snapshot.revision,
               event,
               {:worker, due_lease}
             )

    assert duplicate.outcome == :duplicate
    assert duplicate.effects == scheduled.effects
    GenServer.stop(reopened)
  end

  test "DETS rejects a syntactically valid retry effect with forged commit-relative timing" do
    clock = start_supervised!({Agent, fn -> @created_at end}, id: {Agent, make_ref()})
    path = temporary_dets_path()
    task_id = "dets-forged-retry-timing"
    event_id = "dets-forged-retry-timing-event"

    persist_dets_transition!(
      path,
      :mcp_tasks_retry_forged_timing,
      clock,
      task_id,
      retry_work(task_id, [@retry_delay_ms]),
      event!(Event.retry_requested(retry_error(1), "temporary", id: event_id))
    )

    rewrite_dets_task!(
      path,
      :mcp_tasks_retry_forged_timing_writer,
      task_id,
      fn entry ->
        put_in(
          entry,
          ["seenEvents", event_id, "effects", "retry", "retryAt"],
          @created_at
        )
      end
    )

    assert_dets_reopen_rejected!(
      path,
      :mcp_tasks_retry_forged_timing,
      clock,
      task_id,
      :retry_effect_timestamp_mismatch
    )
  end

  test "DETS rejects a forged exhausted disposition that disagrees with policy" do
    clock = start_supervised!({Agent, fn -> @created_at end}, id: {Agent, make_ref()})
    path = temporary_dets_path()
    task_id = "dets-forged-retry-disposition"
    event_id = "dets-forged-retry-disposition-event"

    persist_dets_transition!(
      path,
      :mcp_tasks_retry_forged_disposition,
      clock,
      task_id,
      retry_work(task_id, [@retry_delay_ms]),
      event!(Event.retry_requested(retry_error(1), "temporary", id: event_id))
    )

    rewrite_dets_task!(
      path,
      :mcp_tasks_retry_forged_disposition_writer,
      task_id,
      fn entry ->
        put_in(entry, ["seenEvents", event_id, "effects", "retry"], %{
          "disposition" => "exhausted",
          "retryAt" => nil,
          "delayMs" => nil,
          "retryCount" => 0
        })
      end
    )

    assert_dets_reopen_rejected!(
      path,
      :mcp_tasks_retry_forged_disposition,
      clock,
      task_id,
      :retry_effect_policy_mismatch
    )
  end

  test "DETS rejects retry effects attached to a non-retry event" do
    clock = start_supervised!({Agent, fn -> @created_at end}, id: {Agent, make_ref()})
    path = temporary_dets_path()
    task_id = "dets-retry-effect-kind"
    event_id = "dets-retry-effect-kind-event"

    persist_dets_transition!(
      path,
      :mcp_tasks_retry_effect_kind,
      clock,
      task_id,
      retry_work(task_id, [0]),
      event!(Event.completed(%{"ok" => true}, id: event_id))
    )

    rewrite_dets_task!(
      path,
      :mcp_tasks_retry_effect_kind_writer,
      task_id,
      fn entry ->
        committed_at = get_in(entry, ["seenEvents", event_id, "committedAt"])

        put_in(entry, ["seenEvents", event_id, "effects"], %{
          "retry" => %{
            "disposition" => "scheduled",
            "retryAt" => committed_at,
            "delayMs" => 0,
            "retryCount" => 1
          }
        })
      end
    )

    assert_dets_reopen_rejected!(
      path,
      :mcp_tasks_retry_effect_kind,
      clock,
      task_id,
      :event_effect_mismatch
    )
  end

  test "Runner executes an explicit retry only when its durable delay is due" do
    %{clock: clock, store_ref: store_ref} = memory_store()
    task_id = "runner-retry-once"
    counter = start_supervised!({Agent, fn -> 0 end})
    work = retry_work(task_id, [@retry_delay_ms], "retry_once")
    _snapshot = create_unclaimed!(store_ref, task_id, work)
    runner = start_runner!(store_ref, counter)

    assert_receive {:retry_execution, ^task_id, 1, first_work}, 1_000
    assert first_work.idempotency_key == task_id

    scheduled = eventually_snapshot!(store_ref, task_id, &(&1.retry_count == 1))
    assert scheduled.task.status == :working
    assert scheduled.retry_at == "2026-08-24T10:01:00.001Z"

    send(runner, :recover)
    refute_receive {:retry_execution, ^task_id, 2, _work}, 20

    advance_clock(clock, @retry_delay_ms + 1)
    send(runner, :recover)

    assert_receive {:retry_execution, ^task_id, 2, second_work}, 1_000
    assert second_work.idempotency_key == first_work.idempotency_key

    completed = eventually_snapshot!(store_ref, task_id, &(&1.task.status == :completed))
    assert completed.task.result["attempt"] == 2
    assert completed.task.result["idempotencyKey"] == task_id
    assert completed.retry_count == 1
    assert completed.retry_at == nil
    assert completed.last_failure["error"]["data"] == %{"attempt" => 1}
    assert Agent.get(counter, & &1) == 2
  end

  test "runner restart during backoff loses no work and cannot bypass store time" do
    %{clock: clock, store_ref: store_ref} = memory_store()
    task_id = "runner-restart-backoff"
    counter = start_supervised!({Agent, fn -> 0 end})

    _snapshot =
      create_unclaimed!(
        store_ref,
        task_id,
        retry_work(task_id, [@retry_delay_ms], "retry_once")
      )

    first_runner = start_runner!(store_ref, counter)
    assert_receive {:retry_execution, ^task_id, 1, _work}, 1_000
    scheduled = eventually_snapshot!(store_ref, task_id, &(&1.retry_count == 1))
    assert scheduled.retry_at == "2026-08-24T10:01:00.001Z"
    GenServer.stop(first_runner, :normal, 1_000)

    replacement = start_runner!(store_ref, counter)
    _bootstrapped = :sys.get_state(replacement)
    send(replacement, :recover)
    refute_receive {:retry_execution, ^task_id, 2, _work}, 20
    assert Agent.get(counter, & &1) == 1

    advance_clock(clock, @retry_delay_ms + 1)
    send(replacement, :recover)
    assert_receive {:retry_execution, ^task_id, 2, _work}, 1_000

    completed = eventually_snapshot!(store_ref, task_id, &(&1.task.status == :completed))
    assert completed.task.result["idempotencyKey"] == task_id
    assert completed.retry_count == 1
  end

  test "zero-delay retry rechecks authoritative time when recovery scanning is disabled" do
    %{clock: clock, store_ref: store_ref} = memory_store()
    task_id = "retry-zero-delay-fixed-clock"
    counter = start_supervised!({Agent, fn -> 0 end})
    work = retry_work(task_id, [0], "retry_once")
    snapshot = create_unclaimed!(store_ref, task_id, work)
    runner = start_runner!(store_ref, counter, recover: false)

    fallback = fn _cancellation -> flunk("configured WorkExecutor was not used") end
    assert :ok = Runner.start_task(runner, snapshot, fallback)
    assert_receive {:retry_execution, ^task_id, 1, _work}, 1_000

    scheduled = eventually_snapshot!(store_ref, task_id, &(&1.retry_count == 1))
    assert scheduled.retry_at == "2026-08-24T10:00:00.001Z"
    refute_receive {:retry_execution, ^task_id, 2, _work}, 20

    advance_clock(clock, 1)
    assert_receive {:retry_execution, ^task_id, 2, _work}, 1_000

    completed = eventually_snapshot!(store_ref, task_id, &(&1.task.status == :completed))
    assert completed.task.result["attempt"] == 2
    assert Agent.get(counter, & &1) == 2
  end

  test "a duplicate retry acknowledgement immediately rechecks authoritative eligibility" do
    %{clock: clock, store: store} = memory_store()
    faults = start_supervised!({Agent, fn -> %{duplicate_retry: 1} end})
    task_id = "duplicate-retry-recheck"
    counter = start_supervised!({Agent, fn -> 0 end}, id: {Agent, make_ref()})

    fault_store =
      {FaultStore,
       %{
         clock: clock,
         faults: faults,
         store: store
       }}

    snapshot =
      create_unclaimed!(
        fault_store,
        task_id,
        retry_work(task_id, [@retry_delay_ms], "retry_once")
      )

    runner = start_runner!(fault_store, counter, recover: false)
    fallback = fn _cancellation -> flunk("configured WorkExecutor was not used") end

    assert :ok = Runner.start_task(runner, snapshot, fallback)
    assert_receive {:retry_execution, ^task_id, 1, _work}, 1_000
    assert_receive {:retry_execution, ^task_id, 2, _work}, 1_000

    completed = eventually_snapshot!(fault_store, task_id, &(&1.task.status == :completed))
    assert completed.retry_count == 1
    assert Agent.get(faults, & &1.duplicate_retry) == 0
    assert Agent.get(counter, & &1) == 2
  end

  test "a transient retry release failure preserves the local path without recovery scanning" do
    %{clock: clock, store: store} = memory_store()
    faults = start_supervised!({Agent, fn -> %{release: 1} end})
    task_id = "retry-release-failure"
    counter = start_supervised!({Agent, fn -> 0 end}, id: {Agent, make_ref()})

    fault_store =
      {FaultStore,
       %{
         clock: clock,
         faults: faults,
         store: store
       }}

    snapshot =
      create_unclaimed!(
        fault_store,
        task_id,
        retry_work(task_id, [0], "retry_once")
      )

    runner = start_runner!(fault_store, counter, recover: false)
    fallback = fn _cancellation -> flunk("configured WorkExecutor was not used") end

    assert :ok = Runner.start_task(runner, snapshot, fallback)
    assert_receive {:retry_execution, ^task_id, 1, _work}, 1_000
    _scheduled = eventually_snapshot!(fault_store, task_id, &(&1.retry_count == 1))
    advance_clock(clock, 1)

    assert_receive {:retry_execution, ^task_id, 2, _work}, 1_000

    completed = eventually_snapshot!(fault_store, task_id, &(&1.task.status == :completed))
    assert completed.retry_count == 1
    assert Agent.get(faults, & &1.release) == 0
    assert Agent.get(counter, & &1) == 2
  end

  test "Runner terminal-fails an explicit retry after the finite policy is exhausted" do
    %{clock: clock, store_ref: store_ref} = memory_store()
    task_id = "retry-policy-exhausted"
    counter = start_supervised!({Agent, fn -> 0 end})

    _snapshot =
      create_unclaimed!(
        store_ref,
        task_id,
        retry_work(task_id, [@retry_delay_ms], "always_retry")
      )

    runner = start_runner!(store_ref, counter)
    assert_receive {:retry_execution, ^task_id, 1, _work}, 1_000
    _scheduled = eventually_snapshot!(store_ref, task_id, &(&1.retry_count == 1))

    advance_clock(clock, @retry_delay_ms + 1)
    send(runner, :recover)
    assert_receive {:retry_execution, ^task_id, 2, _work}, 1_000

    failed = eventually_snapshot!(store_ref, task_id, &(&1.task.status == :failed))
    assert failed.retry_count == 1
    assert failed.retry_at == nil
    assert failed.task.error["data"] == %{"attempt" => 2}
    assert Agent.get(counter, & &1) == 2

    send(runner, :recover)
    refute_receive {:retry_execution, ^task_id, 3, _work}, 20
  end

  test "cancellation during backoff clears availability and prevents a later attempt" do
    %{clock: clock, store_ref: store_ref} = memory_store()
    task_id = "retry-cancelled"
    counter = start_supervised!({Agent, fn -> 0 end})

    _snapshot =
      create_unclaimed!(
        store_ref,
        task_id,
        retry_work(task_id, [@retry_delay_ms], "always_retry")
      )

    runner = start_runner!(store_ref, counter)
    assert_receive {:retry_execution, ^task_id, 1, _work}, 1_000
    _scheduled = eventually_snapshot!(store_ref, task_id, &(&1.retry_count == 1))

    cancel_access = authorize!(store_ref, {:cancel, task_id})
    assert :ok = Runner.cancel(runner, task_id, cancel_access)

    cancelled = snapshot!(store_ref, task_id)
    assert cancelled.task.status == :cancelled
    assert cancelled.retry_at == nil

    advance_clock(clock, @retry_delay_ms + 1)
    send(runner, :recover)
    refute_receive {:retry_execution, ^task_id, 2, _work}, 20
    assert Agent.get(counter, & &1) == 1
  end

  test "accepted input replays across retry without another input request event" do
    %{clock: clock, store: store, store_ref: store_ref} = memory_store()
    task_id = "retry-input-replay"
    counter = start_supervised!({Agent, fn -> 0 end})
    request = input_request()
    response = %{"action" => "accept", "content" => %{"approved" => true}}

    work =
      Work.new!(
        task_id,
        "test/retry",
        %{
          "mode" => "input_retry",
          "key" => "approval",
          "request" => request
        },
        retry_policy: RetryPolicy.new!([@retry_delay_ms])
      )

    _snapshot = create_unclaimed!(store_ref, task_id, work)
    runner = start_runner!(store_ref, counter)
    assert_receive {:retry_execution, ^task_id, 1, _work}, 1_000

    waiting = eventually_snapshot!(store_ref, task_id, &(&1.task.status == :input_required))
    assert waiting.input_history == %{"approval" => request}

    update_access = authorize!(store_ref, {:update, task_id})
    assert :ok = Runner.update(runner, task_id, %{"approval" => response}, update_access)
    assert_receive {:retry_input, 1, {:ok, ^response}}, 1_000

    _scheduled = eventually_snapshot!(store_ref, task_id, &(&1.retry_count == 1))
    advance_clock(clock, @retry_delay_ms + 3)
    send(runner, :recover)

    assert_receive {:retry_execution, ^task_id, 2, _work}, 1_000
    assert_receive {:retry_input, 2, {:ok, ^response}}, 1_000

    completed = eventually_snapshot!(store_ref, task_id, &(&1.task.status == :completed))
    assert completed.task.result["input"] == response

    history_access = authorize!(store_ref, {:get, task_id})
    assert {:ok, entries} = Memory.history(store, task_id, history_access)

    assert Enum.map(entries, & &1.event.kind) == [
             :input_requested,
             :input_responses_accepted,
             :retry_requested,
             :completed
           ]
  end

  test "retry from a fallback without WorkExecutor fails clearly and consumes no policy entry" do
    %{store: store, store_ref: store_ref} = memory_store()
    task_id = "fallback-retry-rejected"
    snapshot = create_unclaimed!(store_ref, task_id, retry_work(task_id, [0]))
    {:ok, runner} = Runner.start_link(store: store_ref, recovery_interval_ms: 60_000)
    Process.unlink(runner)
    stop_runner_on_exit(runner)

    fallback = fn _cancellation -> {:retry, retry_error(1), "retry me"} end
    assert :ok = Runner.start_task(runner, snapshot, fallback)

    failed = eventually_snapshot!(store_ref, task_id, &(&1.task.status == :failed))

    assert failed.task.error["message"] ==
             "Task worker requested retry without a configured durable executor"

    assert failed.retry_count == 0
    assert failed.retry_at == nil

    access = authorize!(store_ref, {:get, task_id})
    assert {:ok, [%{event: %{kind: :failed}}]} = Memory.history(store, task_id, access)
  end

  test "executor exceptions and invalid returns fail closed instead of consuming retry policy" do
    for mode <- ["raise", "invalid"] do
      %{store_ref: store_ref} = memory_store()
      task_id = "retry-fail-closed-#{mode}"
      counter = start_supervised!({Agent, fn -> 0 end}, id: {Agent, mode})
      _snapshot = create_unclaimed!(store_ref, task_id, retry_work(task_id, [0], mode))
      runner = start_runner!(store_ref, counter)

      assert_receive {:retry_execution, ^task_id, 1, _work}, 1_000
      failed = eventually_snapshot!(store_ref, task_id, &(&1.task.status == :failed))

      assert failed.task.error["message"] == "Durable task executor failed"
      assert failed.retry_count == 0
      assert failed.retry_at == nil
      assert Agent.get(counter, & &1) == 1
      GenServer.stop(runner, :normal, 1_000)
    end
  end

  test "a valid failed outcome remains terminal even when retry delays exist" do
    %{store_ref: store_ref} = memory_store()
    task_id = "retry-explicit-failure"
    counter = start_supervised!({Agent, fn -> 0 end})
    _snapshot = create_unclaimed!(store_ref, task_id, retry_work(task_id, [0, 0], "failed"))
    _runner = start_runner!(store_ref, counter)

    assert_receive {:retry_execution, ^task_id, 1, _work}, 1_000
    failed = eventually_snapshot!(store_ref, task_id, &(&1.task.status == :failed))

    assert failed.task.error["message"] == "terminal failure"
    assert failed.retry_count == 0
    assert failed.retry_at == nil
    assert Agent.get(counter, & &1) == 1
  end

  defp persist_dets_transition!(path, table, clock, task_id, work, event) do
    {:ok, server} =
      Dets.start_link(
        path: path,
        table: table,
        clock: fn -> Agent.get(clock, & &1) end
      )

    store_ref = {Dets, server}
    snapshot = create_unclaimed!(store_ref, task_id, work)
    assert {:ok, ^snapshot, lease} = Store.claim(store_ref, task_id, "writer", @lease_ms)

    assert {:ok, %Transition{outcome: :applied}} =
             Store.transition(
               store_ref,
               task_id,
               snapshot.revision,
               event,
               {:worker, lease}
             )

    GenServer.stop(server)
  end

  defp rewrite_dets_task!(path, writer_table, task_id, rewrite) do
    {:ok, ^writer_table} =
      :dets.open_file(
        writer_table,
        file: String.to_charlist(path),
        type: :set
      )

    key = {:task, task_id}
    assert [{^key, binary}] = :dets.lookup(writer_table, key)
    entry = binary |> JSON.decode!() |> rewrite.()
    :ok = :dets.insert(writer_table, {key, JSON.encode!(entry)})
    :ok = :dets.sync(writer_table)
    :ok = :dets.close(writer_table)
  end

  defp assert_dets_reopen_rejected!(path, table, clock, task_id, expected_reason) do
    {starter, monitor} =
      spawn_monitor(fn ->
        Dets.start_link(
          path: path,
          table: table,
          clock: fn -> Agent.get(clock, & &1) end
        )
      end)

    assert_receive {:DOWN, ^monitor, :process, ^starter,
                    {:corrupt_store, {:task, ^task_id}, ^expected_reason}}
  end

  defp memory_store do
    clock = start_supervised!({Agent, fn -> @created_at end}, id: {Agent, make_ref()})

    store =
      start_supervised!(
        {Memory, clock: fn -> Agent.get(clock, & &1) end},
        id: {Memory, make_ref()}
      )

    %{clock: clock, store: store, store_ref: {Memory, store}}
  end

  defp start_runner!(store_ref, counter, opts \\ []) do
    executor_state = %{
      owner: self(),
      counter: counter,
      runner: @runner_name
    }

    {:ok, runner} =
      Runner.start_link(
        name: @runner_name,
        store: store_ref,
        executor: {Executor, executor_state},
        recover: Keyword.get(opts, :recover, true),
        lease_ms: @lease_ms,
        heartbeat_ms: 90_000,
        recovery_interval_ms: 60_000
      )

    Process.unlink(runner)
    stop_runner_on_exit(runner)
    runner
  end

  defp stop_runner_on_exit(runner) do
    on_exit(fn ->
      if Process.alive?(runner), do: GenServer.stop(runner, :normal, 1_000)
    end)
  end

  defp retry_work(task_id, delays_ms, mode \\ "always_retry") do
    Work.new!(
      task_id,
      "test/retry",
      %{"mode" => mode},
      retry_policy: RetryPolicy.new!(delays_ms)
    )
  end

  defp create_unclaimed!(store_ref, task_id, work) do
    access = authorize!(store_ref, {:create, task_id})
    assert {:ok, snapshot} = Store.create(store_ref, task(task_id), work, access)
    snapshot
  end

  defp task(task_id) do
    ProtocolTask.new!(
      id: task_id,
      created_at: @created_at,
      ttl_ms: nil,
      poll_interval_ms: 5,
      status_message: "Task accepted"
    )
  end

  defp retry_error(attempt) do
    %{
      "code" => -32_603,
      "message" => "temporary failure",
      "data" => %{"attempt" => attempt}
    }
  end

  defp snapshot!(store_ref, task_id) do
    access = authorize!(store_ref, {:get, task_id})
    assert {:ok, snapshot} = Store.get(store_ref, task_id, access)
    snapshot
  end

  defp eventually_snapshot!(store_ref, task_id, predicate, attempts \\ 100)

  defp eventually_snapshot!(_store_ref, task_id, _predicate, 0) do
    flunk("task #{task_id} did not reach the expected state")
  end

  defp eventually_snapshot!(store_ref, task_id, predicate, attempts) do
    snapshot = snapshot!(store_ref, task_id)

    if predicate.(snapshot) do
      snapshot
    else
      receive do
      after
        5 -> :ok
      end

      eventually_snapshot!(store_ref, task_id, predicate, attempts - 1)
    end
  end

  defp authorize!(store_ref, action) do
    assert {:ok, access} = Store.authorize(store_ref, context(), action)
    access
  end

  defp advance_clock(clock, milliseconds) do
    Agent.update(clock, fn timestamp ->
      {:ok, datetime, _offset} = DateTime.from_iso8601(timestamp)

      datetime
      |> DateTime.add(milliseconds, :millisecond)
      |> DateTime.to_iso8601()
    end)
  end

  defp input_request do
    %{
      "method" => "elicitation/create",
      "params" => %{
        "message" => "Approve retry?",
        "requestedSchema" => %{
          "type" => "object",
          "properties" => %{"approved" => %{"type" => "boolean"}},
          "required" => ["approved"]
        }
      }
    }
  end

  defp temporary_dets_path do
    path =
      Path.join(
        System.tmp_dir!(),
        "mcp-ex-tasks-retry-#{System.unique_integer([:positive])}.dets"
      )

    on_exit(fn -> File.rm(path) end)
    path
  end

  defp event!({:ok, %Event{} = event}), do: event

  defp context do
    %Context{
      protocol_version: V2026_07_28.version(),
      protocol: V2026_07_28,
      transport: %TransportContext{transport: :direct}
    }
  end
end
