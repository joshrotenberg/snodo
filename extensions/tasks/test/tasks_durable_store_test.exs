defmodule Snodo.TasksDurableStoreTest do
  use ExUnit.Case, async: false

  @moduletag mcp_contract: ["tasks-durable-store"]
  @moduletag :tasks_package

  alias Snodo.Context
  alias Snodo.Extensions.Tasks.Event
  alias Snodo.Extensions.Tasks.Snapshot
  alias Snodo.Extensions.Tasks.Store
  alias Snodo.Extensions.Tasks.Store.Dets
  alias Snodo.Extensions.Tasks.Store.Dets.Access
  alias Snodo.Extensions.Tasks.Store.Dets.Lease
  alias Snodo.Extensions.Tasks.Task, as: ProtocolTask
  alias Snodo.Extensions.Tasks.Transition
  alias Snodo.Extensions.Tasks.Work
  alias Snodo.Protocol.V2026_07_28
  alias Snodo.Transport.Context, as: TransportContext

  @created_at "2026-08-24T10:00:00.000Z"
  @committed_at "2026-08-24T10:00:00.001Z"
  @before_expiry "2026-08-24T10:00:00.999Z"
  @at_expiry "2026-08-24T10:00:01.000Z"
  @after_renewal "2026-08-24T10:00:01.100Z"
  @renewed_expiry "2026-08-24T10:00:01.900Z"

  test "reopen preserves snapshot v3 work, history, and duplicate-event metadata" do
    path = temporary_path("reopen")
    clock = clock(@created_at)
    {server, store} = start_store(path, :mcp_tasks_dets_reopen, clock)
    context = context("tenant-a")
    {snapshot, lease} = create_and_claim!(store, context, "reopen-task", 60_000)

    event = event!(Event.input_requested("approval", input_request(), id: "stable-event"))

    assert {:ok, %Transition{outcome: :applied, event_revision: 1, snapshot: applied}} =
             Store.transition(store, "reopen-task", snapshot.revision, event, {:worker, lease})

    assert applied.work == work("reopen-task")
    assert applied.input_history == %{"approval" => input_request()}
    GenServer.stop(server)

    assert_json_entry(path, "reopen-task")

    {reopened, reopened_store} = start_store(path, :mcp_tasks_dets_reopen, clock)
    read_access = authorize!(reopened_store, context, {:get, "reopen-task"})

    assert {:ok, %Snapshot{revision: 1} = recovered} =
             Store.get(reopened_store, "reopen-task", read_access)

    assert recovered.work == work("reopen-task")
    assert recovered.input_history == %{"approval" => input_request()}

    assert {:ok, [%{event: ^event, committed_at: @committed_at, revision: 1}]} =
             Dets.history(reopened, "reopen-task", read_access)

    assert {:ok, ^recovered, %Lease{} = recovered_lease} =
             Store.claim(reopened_store, "reopen-task", "runner-after-reopen", 60_000)

    assert {:ok,
            %Transition{
              outcome: :duplicate,
              event_revision: 1,
              committed_at: @committed_at,
              snapshot: ^recovered
            }} =
             Store.transition(
               reopened_store,
               "reopen-task",
               snapshot.revision,
               event,
               {:worker, recovered_lease}
             )

    GenServer.stop(reopened)
  end

  test "boot epochs immediately fence old leases and reclaim at a higher generation" do
    path = temporary_path("boot-fence")
    clock = clock(@created_at)
    {server, store} = start_store(path, :mcp_tasks_dets_boot_fence, clock)
    context = context("tenant-a")
    {_snapshot, old_lease} = create_and_claim!(store, context, "fenced-task", 60_000)
    old_access = authorize!(store, context, {:get, "fenced-task"})
    GenServer.stop(server)

    {reopened, reopened_store} = start_store(path, :mcp_tasks_dets_boot_fence, clock)

    assert :not_found = Store.get(reopened_store, "fenced-task", old_access)

    assert {:error, :stale_lease} =
             Store.worker_snapshot(reopened_store, "fenced-task", old_lease)

    assert {:ok, %Snapshot{}, %Lease{} = new_lease} =
             Store.claim(reopened_store, "fenced-task", "new-owner", 60_000)

    assert new_lease.store_id == old_lease.store_id
    assert new_lease.boot_epoch > old_lease.boot_epoch
    assert new_lease.generation == old_lease.generation + 1
    assert {:ok, %Snapshot{}} = Store.worker_snapshot(reopened_store, "fenced-task", new_lease)

    completion = event!(Event.completed(tool_result(), id: "fenced-completion"))

    assert {:error, :stale_lease} =
             Store.transition(
               reopened_store,
               "fenced-task",
               0,
               completion,
               {:worker, old_lease}
             )

    GenServer.stop(reopened)
  end

  test "competing claimers have one winner and claim_next finds remaining work" do
    path = temporary_path("claimers")
    clock = clock(@created_at)
    {server, store} = start_store(path, :mcp_tasks_dets_claimers, clock)
    context = context("tenant-a")
    _first = create!(store, context, "claim-a", 60_000)

    claims =
      ["runner-a", "runner-b"]
      |> Enum.map(fn owner ->
        Task.async(fn -> Store.claim(store, "claim-a", owner, 60_000) end)
      end)
      |> Task.await_many(1_000)

    assert Enum.count(claims, &match?({:ok, %Snapshot{}, %Lease{}}, &1)) == 1
    assert Enum.count(claims, &(&1 == :unavailable)) == 1

    {:ok, %Snapshot{}, winning_lease} =
      Enum.find(claims, &match?({:ok, %Snapshot{}, %Lease{}}, &1))

    assert :ok = Store.release(store, winning_lease)

    assert {:ok, %Snapshot{task: %{id: "claim-a"}}, %Lease{generation: 2}} =
             Store.claim_next(store, "released-recovery", 60_000)

    assert {:error, :stale_lease} = Store.release(store, winning_lease)

    _second = create!(store, context, "claim-b", 60_000)

    assert {:ok, %Snapshot{task: %{id: "claim-b"}}, %Lease{owner_id: "recovery"}} =
             Store.claim_next(store, "recovery", 60_000)

    assert :empty = Store.claim_next(store, "another-runner", 60_000)
    GenServer.stop(server)
  end

  test "renewal keeps a claim live past its original deadline" do
    path = temporary_path("renew")
    clock = clock(@created_at)
    {server, store} = start_store(path, :mcp_tasks_dets_renew, clock)
    context = context("tenant-a")
    {_snapshot, original} = create_and_claim!(store, context, "renew-task", 1_000)

    set_clock(clock, @before_expiry)

    assert {:ok, %Lease{expires_at: @renewed_expiry} = renewed} =
             Store.renew(store, original, 901)

    set_clock(clock, @after_renewal)
    assert :unavailable = Store.claim(store, "renew-task", "too-early", 1_000)
    assert {:error, :stale_lease} = Store.worker_snapshot(store, "renew-task", original)
    assert {:ok, %Snapshot{}} = Store.worker_snapshot(store, "renew-task", renewed)

    set_clock(clock, @renewed_expiry)

    assert {:ok, %Snapshot{}, %Lease{generation: 2}} =
             Store.claim(store, "renew-task", "after-expiry", 1_000)

    GenServer.stop(server)
  end

  test "reaping uses the createdAt TTL boundary and preserves nil TTL records" do
    path = temporary_path("ttl")
    clock = clock(@created_at)
    {server, store} = start_store(path, :mcp_tasks_dets_ttl, clock)
    context = context("tenant-a")
    _finite = create!(store, context, "finite-task", 1_000)
    _unlimited = create!(store, context, "unlimited-task", nil)

    set_clock(clock, @before_expiry)
    assert {:ok, []} = Store.reap(store)

    set_clock(clock, @at_expiry)
    assert {:ok, ["finite-task"]} = Store.reap(store)

    finite_access = authorize!(store, context, {:get, "finite-task"})
    unlimited_access = authorize!(store, context, {:get, "unlimited-task"})
    assert :not_found = Store.get(store, "finite-task", finite_access)

    assert {:ok, %Snapshot{task: %{ttl_ms: nil}}} =
             Store.get(store, "unlimited-task", unlimited_access)

    assert {:ok, []} = Store.reap(store)
    GenServer.stop(server)
  end

  test "unsupported persisted entry versions fail reopen without resetting data" do
    path = temporary_path("corruption")
    clock = clock(@created_at)
    {server, store} = start_store(path, :mcp_tasks_dets_corruption, clock)
    context = context("tenant-a")
    _created = create!(store, context, "valid-task", 60_000)
    GenServer.stop(server)

    {:ok, :mcp_tasks_dets_corruption_writer} =
      :dets.open_file(
        :mcp_tasks_dets_corruption_writer,
        file: String.to_charlist(path),
        type: :set
      )

    :ok =
      :dets.insert(
        :mcp_tasks_dets_corruption_writer,
        {{:task, "corrupt-task"}, JSON.encode!(%{"version" => 999})}
      )

    :ok = :dets.sync(:mcp_tasks_dets_corruption_writer)
    :ok = :dets.close(:mcp_tasks_dets_corruption_writer)

    {starter, monitor} =
      spawn_monitor(fn ->
        Dets.start_link(
          path: path,
          table: :mcp_tasks_dets_corruption,
          clock: clock_fun(clock),
          scope: &scope/1
        )
      end)

    assert_receive {:DOWN, ^monitor, :process, ^starter,
                    {:corrupt_store, {:task, "corrupt-task"}, {:unsupported_entry_version, 999}}}
  end

  defp start_store(path, table, clock) do
    assert {:ok, server} =
             Dets.start_link(
               path: path,
               table: table,
               clock: clock_fun(clock),
               scope: &scope/1
             )

    {server, {Dets, server}}
  end

  defp create!(store, context, id, ttl_ms) do
    access = authorize!(store, context, {:create, id})

    assert {:ok, %Snapshot{} = snapshot} =
             Store.create(store, task(id, ttl_ms), work(id), access)

    snapshot
  end

  defp create_and_claim!(store, context, id, lease_ms) do
    snapshot = create!(store, context, id, 60_000)

    assert {:ok, ^snapshot, %Lease{} = lease} =
             Store.claim(store, id, "test-runner", lease_ms)

    {snapshot, lease}
  end

  defp authorize!(store, context, action) do
    assert {:ok, %Access{} = access} = Store.authorize(store, context, action)
    access
  end

  defp task(id, ttl_ms) do
    ProtocolTask.new!(
      id: id,
      created_at: @created_at,
      ttl_ms: ttl_ms,
      poll_interval_ms: 5,
      status_message: "Task accepted"
    )
  end

  defp work(id), do: Work.new!(id, "test/durable", %{"taskId" => id})

  defp context(tenant) do
    %Context{
      protocol_version: V2026_07_28.version(),
      protocol: V2026_07_28,
      transport: %TransportContext{transport: :direct},
      auth: %{"tenant" => tenant}
    }
  end

  defp scope(%Context{auth: %{"tenant" => tenant}}), do: %{"tenant" => tenant}
  defp scope(%Context{}), do: %{"tenant" => "anonymous"}

  defp clock(initial) do
    start_supervised!({Agent, fn -> initial end}, id: {Agent, make_ref()})
  end

  defp clock_fun(clock), do: fn -> Agent.get(clock, & &1) end
  defp set_clock(clock, timestamp), do: Agent.update(clock, fn _current -> timestamp end)

  defp temporary_path(label) do
    path =
      Path.join(
        System.tmp_dir!(),
        "snodo-tasks-#{label}-#{System.unique_integer([:positive])}.dets"
      )

    on_exit(fn -> File.rm(path) end)
    path
  end

  defp assert_json_entry(path, task_id) do
    {:ok, :mcp_tasks_dets_reopen_reader} =
      :dets.open_file(
        :mcp_tasks_dets_reopen_reader,
        file: String.to_charlist(path),
        type: :set
      )

    assert [{{:task, ^task_id}, binary}] =
             :dets.lookup(:mcp_tasks_dets_reopen_reader, {:task, task_id})

    assert is_binary(binary)
    assert {:ok, %{"version" => 1, "snapshot" => %{"version" => 3}}} = JSON.decode(binary)
    :ok = :dets.close(:mcp_tasks_dets_reopen_reader)
  end

  defp event!({:ok, %Event{} = event}), do: event

  defp input_request do
    %{
      "method" => "elicitation/create",
      "params" => %{
        "message" => "Approve durable work?",
        "requestedSchema" => %{
          "type" => "object",
          "properties" => %{"accepted" => %{"type" => "boolean"}},
          "required" => ["accepted"]
        }
      }
    }
  end

  defp tool_result do
    %{
      "content" => [%{"type" => "text", "text" => "done"}],
      "structuredContent" => %{"durable" => true},
      "isError" => false
    }
  end
end
