defmodule SnodoTest.TasksRecoveryTest.Executor do
  @moduledoc false

  @behaviour Snodo.Extensions.Tasks.WorkExecutor

  alias Snodo.Extensions.Tasks.Runner

  @impl true
  def execute(work, cancellation, state) do
    task_id = work.idempotency_key
    maybe_trap_exits(work.input["mode"])
    send(state.owner, {:recovery_execution_started, task_id, work, self()})

    case work.input["mode"] do
      "complete" ->
        completed_result(task_id, %{"recovered" => true})

      "block" ->
        receive do
          {:release_recovery_work, ^task_id} ->
            completed_result(task_id, %{"released" => true})

          {:complete_recovery_work, ^task_id, marker} ->
            completed_result(task_id, %{"winner" => marker})
        end

      "input" ->
        execute_input(work, cancellation, state)

      "trap_exit" ->
        trap_exit_loop(task_id)
    end
  end

  defp maybe_trap_exits("trap_exit"), do: Process.flag(:trap_exit, true)
  defp maybe_trap_exits(_mode), do: false

  defp trap_exit_loop(task_id) do
    receive do
      {:EXIT, _from, _reason} ->
        trap_exit_loop(task_id)

      {:complete_recovery_work, ^task_id, marker} ->
        completed_result(task_id, %{"winner" => marker})
    end
  end

  defp execute_input(work, cancellation, state) do
    task_id = work.idempotency_key
    key = work.input["key"]
    request = Map.get(state, :request_override, work.input["request"])
    result = Runner.await_input(state.runner, task_id, key, request, cancellation)

    send(
      state.owner,
      {:recovery_input_result, task_id, key, request, result}
    )

    case result do
      {:ok, response} ->
        completed_result(task_id, %{"inputResponse" => response})

      {:error, reason} ->
        {:failed,
         %{
           "code" => -32_603,
           "message" => "Recovered input was rejected",
           "data" => %{"reason" => Atom.to_string(reason)}
         }, "Recovered input was rejected"}
    end
  end

  defp completed_result(task_id, structured) do
    {:completed,
     %{
       "content" => [%{"type" => "text", "text" => "recovered #{task_id}"}],
       "isError" => false,
       "structuredContent" => Map.put(structured, "idempotencyKey", task_id)
     }}
  end
end

defmodule Snodo.TasksRecoveryTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  @moduletag mcp_contract: ["tasks-recovery-claims"]
  @moduletag :tasks_package

  alias Snodo.Context
  alias Snodo.Extensions.Tasks.Event
  alias Snodo.Extensions.Tasks.Runner
  alias Snodo.Extensions.Tasks.Snapshot
  alias Snodo.Extensions.Tasks.Store
  alias Snodo.Extensions.Tasks.Store.Memory
  alias Snodo.Extensions.Tasks.Store.Memory.Lease
  alias Snodo.Extensions.Tasks.Task, as: ProtocolTask
  alias Snodo.Extensions.Tasks.Transition
  alias Snodo.Extensions.Tasks.Work
  alias Snodo.Protocol.V2026_07_28
  alias Snodo.Transport.Context, as: TransportContext
  alias SnodoTest.TasksRecoveryTest.Executor

  @runner_name Snodo.TasksRecoveryTest.Runner
  @created_at "2026-08-24T10:00:00.000Z"
  @lease_ms 1_000
  # How long to wait for a runner to start work. Promptness is asserted
  # separately where it matters; this only has to outlast a loaded machine.
  @claim_timeout 5_000
  @heartbeat_ms 900

  test "a fresh runner recovers and completes descriptor-bearing unclaimed work" do
    %{store: store, store_ref: store_ref} = memory_store()
    task_id = "recover-unclaimed"
    snapshot = create_unclaimed!(store_ref, task_id, work(task_id, "complete"))

    assert snapshot.revision == 0

    runner = start_runner!(store_ref, "fresh-runner")

    assert_receive {:recovery_execution_started, ^task_id, recovered_work, _worker},
                   @claim_timeout

    assert recovered_work == snapshot.work

    completed = eventually_snapshot!(store_ref, task_id, &(&1.task.status == :completed))

    assert completed.task.result["structuredContent"] == %{
             "idempotencyKey" => task_id,
             "recovered" => true
           }

    assert completed.revision == 1
    assert {:ok, [%{revision: 1, event: %{kind: :completed}}]} = history(store, task_id)
    assert Process.alive?(runner)
  end

  test "a hard-killed runner is reclaimed with a higher generation and the same idempotency key" do
    %{clock: clock, store_ref: store_ref} = memory_store()
    task_id = "recover-fenced"
    snapshot = create_unclaimed!(store_ref, task_id, work(task_id, "block"))

    first_runner = start_runner!(store_ref, "runner-one")

    assert_receive {:recovery_execution_started, ^task_id, first_work, first_worker},
                   @claim_timeout

    assert first_work.idempotency_key == task_id

    first_lease = runner_lease!(first_runner, task_id)
    assert first_lease.generation == 1

    hard_kill!(first_runner, first_worker)

    advance_clock(clock, @lease_ms + 1)
    second_runner = start_runner!(store_ref, "runner-two")

    assert_receive {:recovery_execution_started, ^task_id, second_work, second_worker},
                   @claim_timeout

    second_lease = runner_lease!(second_runner, task_id)
    assert second_work.idempotency_key == first_work.idempotency_key
    assert second_lease.generation > first_lease.generation

    assert {:error, :stale_lease} =
             Store.worker_snapshot(store_ref, task_id, first_lease)

    stale_completion = event!(Event.completed(tool_result(task_id), id: "stale-completion"))

    assert {:error, :stale_lease} =
             Store.transition(
               store_ref,
               task_id,
               snapshot.revision,
               stale_completion,
               {:worker, first_lease}
             )

    send(second_worker, {:release_recovery_work, task_id})
    completed = eventually_snapshot!(store_ref, task_id, &(&1.task.status == :completed))

    assert completed.task.result["structuredContent"]["idempotencyKey"] == task_id
  end

  test "a replaced job cannot use the recovery lease for late outcomes or input" do
    %{clock: clock, store: store, store_ref: store_ref} = memory_store()
    task_id = "recover-local-replacement"
    descriptor = work(task_id, "block")
    _snapshot = create_unclaimed!(store_ref, task_id, descriptor)

    runner = start_runner!(store_ref, "replacement-runner")

    assert_receive {:recovery_execution_started, ^task_id, ^descriptor, _first_worker},
                   @claim_timeout

    first_job = runner_job!(runner, task_id)
    assert first_job.lease.generation == 1

    advance_clock(clock, @lease_ms + 1)
    send(runner, :recover)

    assert_receive {:recovery_execution_started, ^task_id, ^descriptor, replacement_worker},
                   @claim_timeout

    replacement_job = runner_job!(runner, task_id)
    assert replacement_job.ref != first_job.ref
    assert replacement_job.pid == replacement_worker
    assert replacement_job.lease.generation > first_job.lease.generation

    stale_request = input_request("Stale worker must not request input")

    assert {:error, :stale_worker} =
             Runner.await_input(
               runner,
               task_id,
               "stale-input",
               stale_request,
               first_job.token
             )

    unchanged_after_stale_input = snapshot!(store_ref, task_id)
    assert unchanged_after_stale_input.revision == 0
    assert unchanged_after_stale_input.input_history == %{}
    assert {:ok, []} = history(store, task_id)

    stale_outcome = completed_outcome(task_id, "stale-generation")
    send(runner, {first_job.ref, stale_outcome})

    current_job = runner_job!(runner, task_id)
    assert current_job.ref == replacement_job.ref
    assert current_job.pid == replacement_job.pid
    assert current_job.lease.generation == replacement_job.lease.generation

    current = snapshot!(store_ref, task_id)
    assert current.revision == 0
    assert current.task.status == :working

    send(replacement_worker, {:complete_recovery_work, task_id, "replacement-generation"})
    completed = eventually_snapshot!(store_ref, task_id, &(&1.task.status == :completed))

    assert completed.task.result["structuredContent"]["winner"] ==
             "replacement-generation"

    assert {:ok, [%{revision: 1, event: %{kind: :completed}}]} = history(store, task_id)
  end

  test "start_task is idempotent when recovery claimed the new task first" do
    %{store: store, store_ref: store_ref} = memory_store()
    task_id = "recover-before-start"
    descriptor = work(task_id, "block")
    runner = start_runner!(store_ref, "recover-before-start-runner")

    _bootstrapped = :sys.get_state(runner)
    snapshot = create_unclaimed!(store_ref, task_id, descriptor)
    send(runner, :recover)

    assert_receive {:recovery_execution_started, ^task_id, ^descriptor, recovered_worker},
                   @claim_timeout

    recovered_job = runner_job!(runner, task_id)
    owner = self()

    fallback = fn _cancellation ->
      send(owner, {:fallback_execution_started, task_id})
      completed_outcome(task_id, "fallback")
    end

    assert :ok = Runner.start_task(runner, snapshot, fallback)

    same_job = runner_job!(runner, task_id)
    assert same_job.ref == recovered_job.ref
    assert same_job.pid == recovered_job.pid
    assert same_job.lease.generation == recovered_job.lease.generation
    refute_receive {:fallback_execution_started, ^task_id}, 20
    refute_receive {:recovery_execution_started, ^task_id, ^descriptor, _duplicate}, 20

    send(recovered_worker, {:complete_recovery_work, task_id, "recovery"})
    completed = eventually_snapshot!(store_ref, task_id, &(&1.task.status == :completed))

    assert completed.task.result["structuredContent"]["winner"] == "recovery"
    assert {:ok, [%{revision: 1, event: %{kind: :completed}}]} = history(store, task_id)
  end

  test "recovery promptly replaces a trap-exit worker while the new lease remains live" do
    %{clock: clock, store: store, store_ref: store_ref} = realtime_memory_store()
    task_id = "recover-trap-exit"
    descriptor = work(task_id, "trap_exit")
    _snapshot = create_unclaimed!(store_ref, task_id, descriptor)
    runner = start_runner!(store_ref, "trap-exit-runner")

    assert_receive {:recovery_execution_started, ^task_id, ^descriptor, first_worker},
                   @claim_timeout

    first_job = runner_job!(runner, task_id)
    assert first_job.pid == first_worker
    assert first_job.lease.generation == 1

    advance_clock(clock, @lease_ms + 1)
    started_at = System.monotonic_time(:millisecond)
    send(runner, :recover)

    assert_receive {:recovery_execution_started, ^task_id, ^descriptor, replacement_worker},
                   @claim_timeout

    elapsed_ms = System.monotonic_time(:millisecond) - started_at
    replacement_job = runner_job!(runner, task_id)

    assert elapsed_ms < 1_000
    assert replacement_job.pid == replacement_worker
    assert replacement_job.ref != first_job.ref
    assert replacement_job.lease.generation > first_job.lease.generation
    refute Process.alive?(first_worker)

    assert {:ok, %Snapshot{task: %{status: :working}}} =
             Store.worker_snapshot(store_ref, task_id, replacement_job.lease)

    send(replacement_worker, {:complete_recovery_work, task_id, "replacement"})
    completed = eventually_snapshot!(store_ref, task_id, &(&1.task.status == :completed))

    assert completed.task.result["structuredContent"]["winner"] == "replacement"
    assert {:ok, [%{revision: 1, event: %{kind: :completed}}]} = history(store, task_id)
  end

  test "accepted input survives a runner crash and recovery does not append another input event" do
    %{clock: clock, store: store, store_ref: store_ref} = memory_store()
    task_id = "recover-input"
    request = input_request("Approve the recovered operation?")
    response = input_response(true)
    descriptor = input_work(task_id, "approval", request)
    _snapshot = create_unclaimed!(store_ref, task_id, descriptor)

    first_runner = start_runner!(store_ref, "input-runner-one")

    assert_receive {:recovery_execution_started, ^task_id, ^descriptor, first_worker},
                   @claim_timeout

    waiting = eventually_snapshot!(store_ref, task_id, &(&1.task.status == :input_required))
    assert waiting.revision == 1
    assert waiting.input_history == %{"approval" => request}

    hard_kill!(first_runner, first_worker)

    accepted_event =
      event!(
        Event.input_responses_accepted(
          %{"approval" => response},
          id: "offline-input-response"
        )
      )

    update_access = authorize!(store_ref, {:update, task_id})

    assert {:ok, %Transition{outcome: :applied, snapshot: accepted}} =
             Store.transition(
               store_ref,
               task_id,
               waiting.revision,
               accepted_event,
               {:request, update_access}
             )

    assert accepted.revision == 2
    assert accepted.task.status == :working
    assert accepted.accepted_input_responses == %{"approval" => response}

    advance_clock(clock, @lease_ms + 1)
    _second_runner = start_runner!(store_ref, "input-runner-two")

    assert_receive {:recovery_execution_started, ^task_id, ^descriptor, _second_worker},
                   @claim_timeout

    assert_receive {:recovery_input_result, ^task_id, "approval", ^request, {:ok, ^response}},
                   1_000

    completed = eventually_snapshot!(store_ref, task_id, &(&1.task.status == :completed))

    assert completed.revision == 3

    assert completed.task.result["structuredContent"] == %{
             "idempotencyKey" => task_id,
             "inputResponse" => response
           }

    assert completed.input_history == %{"approval" => request}
    assert completed.accepted_input_responses == %{"approval" => response}

    assert {:ok, entries} = history(store, task_id)
    assert Enum.map(entries, & &1.revision) == [1, 2, 3]

    assert Enum.map(entries, & &1.event.kind) == [
             :input_requested,
             :input_responses_accepted,
             :completed
           ]
  end

  test "recovery rejects a reused input key when the request identity changes" do
    %{clock: clock, store: store, store_ref: store_ref} = memory_store()
    task_id = "recover-input-mismatch"
    original_request = input_request("Original request")
    different_request = input_request("Different request")
    descriptor = input_work(task_id, "approval", original_request)
    _snapshot = create_unclaimed!(store_ref, task_id, descriptor)

    first_runner = start_runner!(store_ref, "mismatch-runner-one")

    assert_receive {:recovery_execution_started, ^task_id, ^descriptor, first_worker},
                   @claim_timeout

    waiting = eventually_snapshot!(store_ref, task_id, &(&1.task.status == :input_required))
    assert waiting.revision == 1

    hard_kill!(first_runner, first_worker)
    advance_clock(clock, @lease_ms + 1)

    _second_runner =
      start_runner!(store_ref, "mismatch-runner-two", request_override: different_request)

    assert_receive {:recovery_execution_started, ^task_id, ^descriptor, _second_worker},
                   @claim_timeout

    assert_receive {:recovery_input_result, ^task_id, "approval", ^different_request,
                    {:error, :duplicate_input_key}},
                   1_000

    failed = eventually_snapshot!(store_ref, task_id, &(&1.task.status == :failed))
    assert failed.revision == 2
    assert failed.task.error["message"] == "Recovered input was rejected"
    assert failed.input_history == %{"approval" => original_request}

    assert {:ok, entries} = history(store, task_id)
    assert Enum.map(entries, & &1.event.kind) == [:input_requested, :failed]
  end

  defp memory_store do
    clock = start_supervised!({Agent, fn -> @created_at end})

    store =
      start_supervised!(
        {Memory, clock: fn -> Agent.get(clock, & &1) end},
        id: {Memory, make_ref()}
      )

    %{clock: clock, store: store, store_ref: {Memory, store}}
  end

  defp realtime_memory_store do
    clock = start_supervised!({Agent, fn -> @created_at end})
    origin = System.monotonic_time(:millisecond)

    store =
      start_supervised!(
        {Memory,
         clock: fn ->
           elapsed = System.monotonic_time(:millisecond) - origin
           clock |> Agent.get(& &1) |> add_milliseconds(elapsed)
         end},
        id: {Memory, make_ref()}
      )

    %{clock: clock, store: store, store_ref: {Memory, store}}
  end

  defp start_runner!(store_ref, owner_id, executor_opts \\ []) do
    state =
      executor_opts
      |> Map.new()
      |> Map.merge(%{owner: self(), runner: @runner_name})

    opts = [
      name: @runner_name,
      store: store_ref,
      executor: {Executor, state},
      recover: true,
      owner_id: owner_id,
      lease_ms: @lease_ms,
      heartbeat_ms: @heartbeat_ms,
      recovery_interval_ms: 60_000
    ]

    {:ok, runner} = Runner.start_link(opts)
    Process.unlink(runner)

    on_exit(fn ->
      if Process.alive?(runner), do: GenServer.stop(runner, :normal, 1_000)
    end)

    runner
  end

  defp hard_kill!(runner, worker) do
    supervisor = :sys.get_state(runner).supervisor
    runner_monitor = Process.monitor(runner)
    supervisor_monitor = Process.monitor(supervisor)
    worker_monitor = Process.monitor(worker)

    _captured =
      capture_log(fn ->
        Process.exit(runner, :kill)
        assert_receive {:DOWN, ^runner_monitor, :process, ^runner, :killed}, 1_000
        assert_receive {:DOWN, ^worker_monitor, :process, ^worker, _reason}, 1_000
        assert_receive {:DOWN, ^supervisor_monitor, :process, ^supervisor, _reason}, 1_000
      end)
  end

  defp runner_lease!(runner, task_id) do
    runner_job!(runner, task_id).lease
  end

  defp runner_job!(runner, task_id) do
    runner
    |> :sys.get_state()
    |> get_in([:jobs, task_id])
    |> case do
      %{pid: pid, ref: ref, lease: %Lease{}} = job when is_pid(pid) and is_reference(ref) ->
        job

      missing ->
        flunk("runner has no current job for #{task_id}: #{inspect(missing)}")
    end
  end

  defp create_unclaimed!(store_ref, task_id, %Work{} = descriptor) do
    task =
      ProtocolTask.new!(
        id: task_id,
        created_at: @created_at,
        ttl_ms: 60_000,
        poll_interval_ms: 5,
        status_message: "Task accepted"
      )

    access = authorize!(store_ref, {:create, task_id})
    assert {:ok, %Snapshot{} = snapshot} = Store.create(store_ref, task, descriptor, access)
    snapshot
  end

  defp authorize!(store_ref, action) do
    assert {:ok, access} = Store.authorize(store_ref, context(), action)
    access
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

  defp snapshot!(store_ref, task_id) do
    access = authorize!(store_ref, {:get, task_id})

    case Store.get(store_ref, task_id, access) do
      {:ok, %Snapshot{} = snapshot} -> snapshot
      other -> flunk("task #{task_id} lookup failed: #{inspect(other)}")
    end
  end

  defp history(store, task_id) do
    access = authorize!({Memory, store}, {:get, task_id})
    Memory.history(store, task_id, access)
  end

  defp advance_clock(clock, milliseconds) do
    Agent.update(clock, &add_milliseconds(&1, milliseconds))
  end

  defp add_milliseconds(timestamp, milliseconds) do
    {:ok, datetime, _offset} = DateTime.from_iso8601(timestamp)

    datetime
    |> DateTime.add(milliseconds, :millisecond)
    |> DateTime.to_iso8601()
  end

  defp work(task_id, mode) do
    Work.new!(task_id, "test/recovery", %{"mode" => mode})
  end

  defp input_work(task_id, key, request) do
    Work.new!(task_id, "test/recovery", %{
      "mode" => "input",
      "key" => key,
      "request" => request
    })
  end

  defp event!({:ok, %Event{} = event}), do: event

  defp tool_result(task_id) do
    %{
      "content" => [%{"type" => "text", "text" => "stale #{task_id}"}],
      "isError" => false,
      "structuredContent" => %{"idempotencyKey" => task_id}
    }
  end

  defp completed_outcome(task_id, marker) do
    {:completed,
     %{
       "content" => [%{"type" => "text", "text" => marker}],
       "isError" => false,
       "structuredContent" => %{
         "idempotencyKey" => task_id,
         "winner" => marker
       }
     }}
  end

  defp input_request(message) do
    %{
      "method" => "elicitation/create",
      "params" => %{
        "message" => message,
        "requestedSchema" => %{
          "type" => "object",
          "properties" => %{"approved" => %{"type" => "boolean"}},
          "required" => ["approved"]
        }
      }
    }
  end

  defp input_response(approved) do
    %{"action" => "accept", "content" => %{"approved" => approved}}
  end

  defp context do
    %Context{
      protocol_version: V2026_07_28.version(),
      protocol: V2026_07_28,
      transport: %TransportContext{transport: :direct}
    }
  end
end
