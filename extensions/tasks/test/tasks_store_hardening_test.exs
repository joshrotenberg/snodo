defmodule Snodo.TasksStoreHardeningTest do
  use ExUnit.Case, async: false

  @moduletag mcp_contract: ["tasks-store-hardening"]
  @moduletag :tasks_package

  alias Snodo.Context
  alias Snodo.Extensions.Tasks.Event
  alias Snodo.Extensions.Tasks.Snapshot
  alias Snodo.Extensions.Tasks.Store
  alias Snodo.Extensions.Tasks.Store.Memory
  alias Snodo.Extensions.Tasks.Store.Memory.Access
  alias Snodo.Extensions.Tasks.Store.Memory.Lease
  alias Snodo.Extensions.Tasks.Task, as: ProtocolTask
  alias Snodo.Extensions.Tasks.Transition
  alias Snodo.Extensions.Tasks.Work
  alias Snodo.Protocol.V2026_07_28
  alias Snodo.Transport.Context, as: TransportContext

  @created_at "2026-08-24T10:00:00.000Z"
  @requested_at "2026-08-24T10:00:01.000Z"
  @responded_at "2026-08-24T10:00:02.000Z"
  @completed_at "2026-08-24T10:00:03.000Z"

  test "events reject non-JSON terms and round-trip through their JSON representation" do
    events = [
      event!(Event.input_requested("approval", input_request(), id: "event-input")),
      event!(Event.input_responses_accepted(input_responses(), id: "event-responses")),
      event!(Event.completed(tool_result(), id: "event-completed")),
      event!(Event.failed(protocol_error(), "Worker failed", id: "event-failed")),
      event!(Event.cancelled(id: "event-cancelled"))
    ]

    Enum.each(events, fn event ->
      wire = event |> Event.to_map() |> JSON.encode!() |> JSON.decode!()
      assert {:ok, ^event} = Event.from_map(wire)
    end)

    invalid = self()

    assert {:error, _reason} =
             Event.input_requested(
               "approval",
               put_in(input_request(), ["params", "invalid"], invalid),
               id: "bad-input"
             )

    assert {:error, _reason} =
             Event.input_responses_accepted(
               %{"approval" => %{"invalid" => make_ref()}},
               id: "bad-responses"
             )

    assert {:error, _reason} = Event.completed(%{"invalid" => invalid}, id: "bad-result")

    assert {:error, _reason} =
             Event.failed(
               %{"code" => -32_603, "message" => "bad", "data" => fn -> :bad end},
               nil,
               id: "bad-error"
             )
  end

  test "the reducer advances once per applied event and preserves key and terminal invariants" do
    initial = Snapshot.new(task("reducer"))
    assert initial.revision == 0
    assert initial.accepted_input_responses == %{}

    requested = event!(Event.input_requested("approval", input_request(), id: "requested"))
    first = apply!(initial, requested, @requested_at)

    assert first.outcome == :applied
    assert first.snapshot.revision == 1
    assert first.snapshot.task.status == :input_required
    assert is_map(first.effects)

    accepted =
      event!(Event.input_responses_accepted(input_responses(), id: "responses-accepted"))

    second = apply!(first.snapshot, accepted, @responded_at)

    assert second.outcome == :applied
    assert second.snapshot.revision == 2
    assert second.snapshot.task.status == :working
    assert second.snapshot.accepted_input_responses == input_responses()

    reused = event!(Event.input_requested("approval", input_request(), id: "key-reused"))
    assert {:error, _reason} = Transition.apply(second.snapshot, reused, @completed_at)

    completed = event!(Event.completed(tool_result(), id: "finished"))
    third = apply!(second.snapshot, completed, @completed_at)

    assert third.outcome == :applied
    assert third.snapshot.revision == 3
    assert third.snapshot.task.status == :completed

    cancelled = event!(Event.cancelled(id: "too-late"))
    unchanged = apply!(third.snapshot, cancelled, @completed_at)

    assert unchanged.outcome == :unchanged
    assert unchanged.snapshot == third.snapshot
    assert unchanged.event_revision == 3
  end

  test "Memory rejects a stale expected revision without appending the losing event" do
    {server, store} = memory_store()
    context = context("tenant-a")
    {snapshot, lease} = create_task!(store, context, "cas-task")

    completed = event!(Event.completed(tool_result(), id: "cas-completed"))
    failed = event!(Event.failed(protocol_error(), "lost race", id: "cas-failed"))

    assert {:ok, %Transition{outcome: :applied, snapshot: winner}} =
             Store.transition(store, "cas-task", snapshot.revision, completed, worker(lease))

    assert winner.revision == 1

    assert {:conflict, %Snapshot{revision: 1}} =
             Store.transition(store, "cas-task", snapshot.revision, failed, worker(lease))

    access = authorize!(store, context, {:get, "cas-task"})
    assert {:ok, [%{event: ^completed, revision: 1}]} = Memory.history(server, "cas-task", access)
  end

  test "two concurrent writers at one revision produce exactly one committed event" do
    {server, store} = memory_store()
    context = context("tenant-a")
    {snapshot, lease} = create_task!(store, context, "concurrent-cas-task")

    events = [
      event!(Event.completed(tool_result(), id: "concurrent-completed")),
      event!(Event.failed(protocol_error(), "concurrent failure", id: "concurrent-failed"))
    ]

    results =
      Enum.map(events, fn event ->
        Task.async(fn ->
          Store.transition(
            store,
            "concurrent-cas-task",
            snapshot.revision,
            event,
            worker(lease)
          )
        end)
      end)
      |> Task.await_many(1_000)

    assert Enum.count(results, &match?({:ok, %Transition{outcome: :applied}}, &1)) == 1
    assert Enum.count(results, &match?({:conflict, %Snapshot{revision: 1}}, &1)) == 1

    access = authorize!(store, context, {:get, "concurrent-cas-task"})
    assert {:ok, [%{revision: 1}]} = Memory.history(server, "concurrent-cas-task", access)
  end

  test "an event-id retry is idempotent and remembers its original revision" do
    {server, store} = memory_store()
    context = context("tenant-a")
    {snapshot, lease} = create_task!(store, context, "retry-task")

    requested = event!(Event.input_requested("approval", input_request(), id: "stable-id"))
    completed = event!(Event.completed(tool_result(), id: "later-event"))

    assert {:ok, %Transition{outcome: :applied, event_revision: 1, snapshot: after_first}} =
             Store.transition(store, "retry-task", snapshot.revision, requested, worker(lease))

    assert {:ok, %Transition{outcome: :applied, event_revision: 2, snapshot: current}} =
             Store.transition(store, "retry-task", after_first.revision, completed, worker(lease))

    assert {:ok,
            %Transition{
              outcome: :duplicate,
              event_revision: 1,
              snapshot: duplicate_snapshot
            }} =
             Store.transition(store, "retry-task", snapshot.revision, requested, worker(lease))

    assert duplicate_snapshot == current

    reused_id = event!(Event.failed(protocol_error(), nil, id: "stable-id"))

    assert {:error, :event_id_reused} =
             Store.transition(store, "retry-task", current.revision, reused_id, worker(lease))

    access = authorize!(store, context, {:get, "retry-task"})
    assert {:ok, history} = Memory.history(server, "retry-task", access)
    assert Enum.map(history, & &1.revision) == [1, 2]
  end

  test "unchanged transitions acknowledge without changing revision or history" do
    {server, store} = memory_store()
    context = context("tenant-a")
    {snapshot, _lease} = create_task!(store, context, "no-op-task")

    unknown =
      event!(
        Event.input_responses_accepted(
          %{"never-requested" => %{"accepted" => true}},
          id: "unknown-input"
        )
      )

    update_access = authorize!(store, context, {:update, "no-op-task"})

    assert {:ok, %Transition{outcome: :unchanged, snapshot: ^snapshot}} =
             Store.transition(
               store,
               "no-op-task",
               snapshot.revision,
               unknown,
               request(update_access)
             )

    read_access = authorize!(store, context, {:get, "no-op-task"})
    assert {:ok, []} = Memory.history(server, "no-op-task", read_access)

    cancel_access = authorize!(store, context, {:cancel, "no-op-task"})
    first_cancel = event!(Event.cancelled(id: "cancel-once"))

    assert {:ok, %Transition{outcome: :applied, snapshot: cancelled}} =
             Store.transition(
               store,
               "no-op-task",
               snapshot.revision,
               first_cancel,
               request(cancel_access)
             )

    second_cancel = event!(Event.cancelled(id: "cancel-again"))

    assert {:ok, %Transition{outcome: :unchanged, snapshot: same_cancelled}} =
             Store.transition(
               store,
               "no-op-task",
               cancelled.revision,
               second_cancel,
               request(cancel_access)
             )

    assert same_cancelled == cancelled

    assert {:ok, [%{event: ^first_cancel, revision: 1}]} =
             Memory.history(server, "no-op-task", read_access)
  end

  test "request access is scoped and bound to one action and task id" do
    {_server, store} = memory_store()
    tenant_a = context("tenant-a")
    tenant_b = context("tenant-b")
    {_snapshot, _lease} = create_task!(store, tenant_a, "scoped-task")

    tenant_b_get = authorize!(store, tenant_b, {:get, "scoped-task"})
    assert :not_found = Store.get(store, "scoped-task", tenant_b_get)

    cancellation = event!(Event.cancelled(id: "unauthorized-cancel"))
    tenant_b_cancel = authorize!(store, tenant_b, {:cancel, "scoped-task"})

    assert :not_found =
             Store.transition(
               store,
               "scoped-task",
               0,
               cancellation,
               request(tenant_b_cancel)
             )

    tenant_a_get = authorize!(store, tenant_a, {:get, "scoped-task"})

    assert {:error, :unauthorized_action} =
             Store.transition(store, "scoped-task", 0, cancellation, request(tenant_a_get))

    assert {:ok, %Snapshot{revision: 0, task: %{status: :working}}} =
             Store.get(store, "scoped-task", tenant_a_get)
  end

  test "opaque leases reject forgery and cross-task mutation without harming valid authority" do
    {_server, store} = memory_store()
    context = context("tenant-a")
    {_first, first_lease} = create_task!(store, context, "lease-a")
    {_second, second_lease} = create_task!(store, context, "lease-b")
    completion = event!(Event.completed(tool_result(), id: "lease-completion"))

    assert {:error, :stale_lease} =
             Store.transition(store, "lease-b", 0, completion, worker(first_lease))

    forged = struct(Lease)

    assert {:error, :stale_lease} =
             Store.transition(store, "lease-a", 0, completion, worker(forged))

    assert {:ok, %Transition{outcome: :applied, snapshot: completed}} =
             Store.transition(store, "lease-b", 0, completion, worker(second_lease))

    assert completed.task.status == :completed

    {_other_server, other_store} = memory_store()
    {_other_snapshot, other_lease} = create_task!(other_store, context, "other-store-task")

    assert {:error, :stale_lease} =
             Store.transition(store, "lease-a", 0, completion, worker(other_lease))
  end

  defp memory_store do
    scope = fn
      %Context{auth: %{"tenant" => tenant}} -> {:tenant, tenant}
      %Context{} -> :anonymous
    end

    server =
      start_supervised!(
        {Memory, scope: scope, clock: fn -> @completed_at end},
        id: {Memory, make_ref()}
      )

    {server, {Memory, server}}
  end

  defp create_task!(store, context, id) do
    access = authorize!(store, context, {:create, id})
    work = Work.new!(id, "test", %{"taskId" => id})

    assert {:ok, %Snapshot{} = snapshot} = Store.create(store, task(id), work, access)

    assert {:ok, %Snapshot{} = claimed, %Lease{} = lease} =
             Store.claim(store, id, "hardening-test", 60_000)

    assert claimed == snapshot
    {claimed, lease}
  end

  defp authorize!(store, context, action) do
    assert {:ok, %Access{} = access} = Store.authorize(store, context, action)
    access
  end

  defp apply!(snapshot, event, committed_at) do
    assert {:ok, %Transition{} = transition} =
             Transition.apply(snapshot, event, committed_at)

    transition
  end

  defp event!({:ok, %Event{} = event}), do: event

  defp request(%Access{} = access), do: {:request, access}
  defp worker(%Lease{} = lease), do: {:worker, lease}

  defp task(id) do
    ProtocolTask.new!(
      id: id,
      created_at: @created_at,
      ttl_ms: 60_000,
      poll_interval_ms: 5,
      status_message: "Task accepted"
    )
  end

  defp context(tenant) do
    %Context{
      protocol_version: V2026_07_28.version(),
      protocol: V2026_07_28,
      transport: %TransportContext{transport: :direct},
      auth: %{"tenant" => tenant}
    }
  end

  defp input_request do
    %{
      "method" => "elicitation/create",
      "params" => %{
        "message" => "Approve the durable operation?",
        "requestedSchema" => %{
          "type" => "object",
          "properties" => %{"accepted" => %{"type" => "boolean"}},
          "required" => ["accepted"]
        }
      }
    }
  end

  defp input_responses do
    %{"approval" => %{"action" => "accept", "content" => %{"accepted" => true}}}
  end

  defp tool_result do
    %{
      "content" => [%{"type" => "text", "text" => "done ✓"}],
      "structuredContent" => %{"durable" => true},
      "isError" => false
    }
  end

  defp protocol_error do
    %{"code" => -32_603, "message" => "Task worker failed"}
  end
end
