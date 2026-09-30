defmodule SnodoTest.TasksLimitsExecutor do
  @moduledoc false

  @behaviour Snodo.Extensions.Tasks.WorkExecutor

  # Reports each attempt and waits for the test to choose its outcome.
  @impl true
  def execute(work, _cancellation, owner) do
    send(owner, {:limits_attempt, work.idempotency_key, self()})

    receive do
      {:limits_outcome, outcome} -> outcome
    end
  end
end

defmodule Snodo.TasksLimitsTest do
  use ExUnit.Case, async: false

  @moduletag :tasks_package

  alias Snodo.Context
  alias Snodo.Extensions.Tasks.Event
  alias Snodo.Extensions.Tasks.RetryPolicy
  alias Snodo.Extensions.Tasks.Runner
  alias Snodo.Extensions.Tasks.Snapshot
  alias Snodo.Extensions.Tasks.Store
  alias Snodo.Extensions.Tasks.Store.Dets
  alias Snodo.Extensions.Tasks.Store.Memory
  alias Snodo.Extensions.Tasks.Task, as: ProtocolTask
  alias Snodo.Extensions.Tasks.Transition
  alias Snodo.Extensions.Tasks.Work
  alias Snodo.Protocol.V2026_07_28
  alias Snodo.Transport.Context, as: TransportContext
  alias SnodoTest.TasksLimitsExecutor
  alias SnodoTest.TasksSubscriptionHub
  alias SnodoTest.TasksSubscriptionSource
  alias SnodoTest.TasksTestSupport, as: TasksSupport

  @created_at "2026-09-27T10:00:00.000Z"
  @ttl_ms 60_000

  describe "runner max_jobs" do
    test "creation at the limit is refused, stores nothing, and succeeds after a job" do
      %{runtime: runtime, store: store} = start_tasks(runner: [max_jobs: 2])
      {first, first_worker} = create_blocking!(runtime, "jobs-1")
      {_second, second_worker} = create_blocking!(runtime, "jobs-2")

      assert {:ok, %{"error" => error}} = call_blocking(runtime, "jobs-3")

      assert error == %{
               "code" => -32_603,
               "message" => "Task capacity exhausted",
               "data" => %{"retryable" => true, "limit" => "max_jobs"}
             }

      assert map_size(:sys.get_state(store).entries) == 2

      send(first_worker, {:tasks_release, "jobs-1"})
      TasksSupport.eventually_get(runtime, first, &completed?/1)

      {_third, third_worker} = create_blocking!(runtime, "jobs-3")
      send(second_worker, {:tasks_release, "jobs-2"})
      send(third_worker, {:tasks_release, "jobs-3"})
    end

    test "start_task at the limit leaves the stored task unclaimed" do
      store = start_supervised!({Memory, scope: :shared})
      store_ref = {Memory, store}
      runner = start_supervised!({Runner, store: store_ref, max_jobs: 1})
      first = create_stored!(store_ref, "start-1")
      second = create_stored!(store_ref, "start-2")

      assert :ok = Runner.start_task(runner, first, blocking_work())
      assert_receive {:blocking_work_started, first_worker}, 1_000

      assert {:error, {:capacity_exceeded, :max_jobs}} =
               Runner.start_task(runner, second, blocking_work())

      assert :sys.get_state(store).entries["start-2"].claim == nil

      send(first_worker, :finish)
      wait_until(fn -> :sys.get_state(runner).jobs == %{} end)

      assert :ok = Runner.start_task(runner, second, blocking_work())
      assert_receive {:blocking_work_started, second_worker}, 1_000
      send(second_worker, :finish)
    end

    test "a due retry waits for a free slot instead of exceeding the limit" do
      clock = start_clock(@created_at)
      store = start_supervised!({Memory, scope: :shared, clock: clock_fun(clock)})
      store_ref = {Memory, store}

      runner =
        start_supervised!(
          {Runner,
           store: store_ref,
           executor: {TasksLimitsExecutor, self()},
           max_jobs: 1,
           reap_interval_ms: nil}
        )

      policy = RetryPolicy.new!([20])
      work = Work.new!("retrying", "limits/retry", %{}, retry_policy: policy)
      retrying = create_stored!(store_ref, "retrying", work: work)

      holder = create_stored!(store_ref, "holder")

      assert :ok = Runner.start_task(runner, retrying, blocking_work())
      assert_receive {:limits_attempt, "retrying", first_attempt}, 1_000
      error = %{"code" => -32_603, "message" => "temporary"}
      send(first_attempt, {:limits_outcome, {:retry, error, "Retrying"}})

      # The store clock stands still, so the retry stays deferred and cannot
      # take the slot back before the holder starts.
      wait_until(fn -> :sys.get_state(runner).jobs == %{} end)
      assert :ok = Runner.start_task(runner, holder, blocking_work())
      assert_receive {:limits_attempt, "holder", holder_worker}, 1_000

      wait_until(fn -> :queue.member("retrying", awaiting_slot(runner)) end)
      refute_received {:limits_attempt, "retrying", _worker}

      advance_clock(clock, 1_000)
      send(holder_worker, {:limits_outcome, {:completed, %{"holder" => true}}})

      assert_receive {:limits_attempt, "retrying", second_attempt}, 2_000
      send(second_attempt, {:limits_outcome, {:completed, %{"retried" => true}}})
      wait_until(fn -> :sys.get_state(runner).jobs == %{} end)
      assert :sys.get_state(store).entries["retrying"].snapshot.task.status == :completed
    end
  end

  test "a worker past max_runtime_ms is stopped and its task fails" do
    %{runtime: runtime, runner: runner} = start_tasks(runner: [max_runtime_ms: 50])
    {task_id, worker} = create_blocking!(runtime, "overrun")
    monitor = Process.monitor(worker)

    assert_receive {:DOWN, ^monitor, :process, ^worker, reason}, 2_000
    assert reason in [:killed, :noproc]

    assert {:ok, %{"result" => failed}} =
             TasksSupport.eventually_get(runtime, task_id, &(&1["status"] == "failed"))

    assert failed["statusMessage"] == "Task exceeded its maximum runtime"
    assert failed["error"]["code"] == -32_603
    assert :sys.get_state(runner).jobs == %{}
  end

  test "creation over max_active_tasks_per_scope is refused for that scope only" do
    %{runtime: runtime} = start_tasks(store: [max_active_tasks_per_scope: 2])
    alice = [auth: %{"tenant" => "alice"}]
    bob = [auth: %{"tenant" => "bob"}]

    {alice_first, alice_first_worker} = create_blocking!(runtime, "alice-1", alice)
    {_alice_second, alice_second_worker} = create_blocking!(runtime, "alice-2", alice)

    assert {:ok, %{"error" => error}} = call_blocking(runtime, "alice-3", alice)
    assert error["code"] == -32_603
    assert error["data"]["limit"] == "max_active_tasks_per_scope"
    assert error["data"]["retryable"] == true

    {_bob_first, bob_worker} = create_blocking!(runtime, "bob-1", bob)

    send(alice_first_worker, {:tasks_release, "alice-1"})
    TasksSupport.eventually_get(runtime, alice_first, &completed?/1, alice)

    {_alice_third, alice_third_worker} = create_blocking!(runtime, "alice-3", alice)

    for {worker, label} <- [
          {alice_second_worker, "alice-2"},
          {alice_third_worker, "alice-3"},
          {bob_worker, "bob-1"}
        ] do
      send(worker, {:tasks_release, label})
    end
  end

  test "creation over max_tasks is refused until expired tasks are reaped" do
    clock = start_clock(ProtocolTask.timestamp())

    %{runtime: runtime, runner: runner, store: store} =
      start_tasks(
        store: [max_tasks: 2, clock: clock_fun(clock)],
        runner: [reap_interval_ms: nil]
      )

    for label <- ["stored-1", "stored-2"] do
      assert {:ok, %{"result" => %{"taskId" => task_id}}} =
               TasksSupport.call(runtime, label, "slow_compute", %{"label" => label})

      TasksSupport.eventually_get(runtime, task_id, &completed?/1)
    end

    assert {:ok, %{"error" => error}} = call_blocking(runtime, "stored-3")
    assert error["data"] == %{"retryable" => true, "limit" => "max_tasks"}
    assert map_size(:sys.get_state(store).entries) == 2

    advance_clock(clock, @ttl_ms + 1_000)
    assert {:ok, reaped} = Runner.reap(runner)
    assert length(reaped) == 2

    {_task_id, worker} = create_blocking!(runtime, "stored-3")
    send(worker, {:tasks_release, "stored-3"})
  end

  test "an expired task is unknown to every task method before reaping" do
    clock = start_clock(ProtocolTask.timestamp())
    hub = start_supervised!({TasksSubscriptionHub, owner: self()})

    %{runtime: runtime, runner: runner, store: store} =
      start_tasks(
        store: [clock: clock_fun(clock)],
        runner: [reap_interval_ms: nil],
        runtime: [subscription_source: {TasksSubscriptionSource, hub}]
      )

    {task_id, worker} = create_blocking!(runtime, "expiring")

    assert {:ok, %{"result" => %{"status" => "working"}}} =
             TasksSupport.get(runtime, "live", task_id)

    # The extension's clock set createdAt shortly after the store clock started.
    advance_clock(clock, @ttl_ms + 1_000)
    unknown = %{"code" => -32_602, "message" => "Unknown or inaccessible taskId"}

    assert {:ok, %{"error" => ^unknown}} = TasksSupport.get(runtime, "expired-1", task_id)

    assert {:ok, %{"error" => ^unknown}} =
             TasksSupport.update(runtime, "expired-2", task_id, %{"answer" => %{}})

    assert {:ok, %{"error" => ^unknown}} = TasksSupport.cancel(runtime, "expired-3", task_id)

    listen =
      TasksSupport.request("expired-listen", "subscriptions/listen", %{
        "notifications" => %{"taskIds" => [task_id]}
      })

    assert {:stream, subscription} = TasksSupport.dispatch(runtime, listen)
    assert_receive {:tasks_subscription_opened, "expired-listen", %{}}, 1_000
    assert subscription.extension_filters == %{}
    assert :ok = Snodo.Subscription.close(subscription, :complete)

    assert Map.has_key?(:sys.get_state(store).entries, task_id)
    monitor = Process.monitor(worker)
    assert {:ok, [^task_id]} = Runner.reap(runner)
    assert_receive {:DOWN, ^monitor, :process, ^worker, _reason}, 2_000
  end

  test "a runner with default options reaps expired tasks every minute" do
    clock = start_clock(@created_at)
    store = start_supervised!({Memory, scope: :shared, clock: clock_fun(clock)})
    store_ref = {Memory, store}
    runner = start_supervised!({Runner, store: store_ref})

    state = :sys.get_state(runner)
    assert state.reap_interval_ms == 60_000
    first_timer = Process.read_timer(state.reap_timer)
    assert is_integer(first_timer) and first_timer > 0 and first_timer <= 60_000

    create_stored!(store_ref, "reaped-by-default", ttl_ms: 1_000)
    advance_clock(clock, 1_000)

    # The message the armed timer delivers.
    send(runner, :reap)
    rearmed = :sys.get_state(runner)

    assert :sys.get_state(store).entries == %{}
    refute rearmed.reap_timer == state.reap_timer
    assert is_integer(Process.read_timer(rearmed.reap_timer))
    assert Process.read_timer(state.reap_timer) == false
  end

  describe "Store.Dets limits and expiry" do
    test "the counts hold after the store reopens and free up as tasks finish" do
      path = temporary_path("limits")
      clock = start_clock(@created_at)
      opts = dets_options(path, :snodo_tasks_limits_reopen, clock)
      server = start_dets!(opts)
      store = {Dets, server}

      create_stored!(store, "alice-1", context: context("alice"))

      assert {:error, {:capacity_exceeded, :max_active_tasks_per_scope}} =
               create_stored(store, "alice-2", context: context("alice"))

      create_stored!(store, "bob-1", context: context("bob"))
      GenServer.stop(server)

      server = start_dets!(opts)
      store = {Dets, server}

      assert {:error, {:capacity_exceeded, :max_active_tasks_per_scope}} =
               create_stored(store, "alice-2", context: context("alice"))

      assert {:ok, %Snapshot{}, lease} = Store.claim(store, "alice-1", "owner", 30_000)
      completed = event!(Event.completed(%{"done" => true}, id: "alice-1-completed"))

      assert {:ok, %Transition{outcome: :applied}} =
               Store.transition(store, "alice-1", 0, completed, {:worker, lease})

      create_stored!(store, "alice-2", context: context("alice"))

      assert {:error, {:capacity_exceeded, :max_tasks}} =
               create_stored(store, "carol-1", context: context("carol"))

      GenServer.stop(server)
      server = start_dets!(opts)
      store = {Dets, server}

      assert {:error, {:capacity_exceeded, :max_tasks}} =
               create_stored(store, "carol-1", context: context("carol"))

      advance_clock(clock, @ttl_ms)
      assert {:ok, reaped} = Store.reap(store)
      assert Enum.sort(reaped) == ["alice-1", "alice-2", "bob-1"]
      create_stored!(store, "carol-1", context: context("carol"))
      GenServer.stop(server)
    end

    test "get and request transitions treat an expired task as unknown before reaping" do
      path = temporary_path("expiry")
      clock = start_clock(@created_at)
      server = start_dets!(dets_options(path, :snodo_tasks_limits_expiry, clock))
      store = {Dets, server}
      create_stored!(store, "expiring", ttl_ms: 1_000)

      get_access = authorize!(store, context("tenant"), {:get, "expiring"})
      assert {:ok, %Snapshot{}} = Store.get(store, "expiring", get_access)

      advance_clock(clock, 1_000)
      assert :not_found = Store.get(store, "expiring", get_access)

      cancel_access = authorize!(store, context("tenant"), {:cancel, "expiring"})
      cancelled = event!(Event.cancelled(id: "expired-cancel"))
      authority = {:request, cancel_access}
      assert :not_found = Store.transition(store, "expiring", 0, cancelled, authority)

      assert {:ok, ["expiring"]} = Store.reap(store)
      GenServer.stop(server)
    end
  end

  test "work input over max_work_input_bytes is refused with -32602" do
    %{runtime: runtime, store: store} =
      start_tasks(extension: [max_work_input_bytes: 200])

    large = %{"label" => String.duplicate("x", 200)}

    assert {:ok, %{"error" => error}} =
             TasksSupport.call(runtime, "large-input", "slow_compute", large)

    assert error["code"] == -32_602
    assert error["message"] == "Task input is larger than 200 bytes"
    assert :sys.get_state(store).entries == %{}

    small = %{"label" => "small"}

    assert {:ok, %{"result" => %{"taskId" => _task_id}}} =
             TasksSupport.call(runtime, "small-input", "slow_compute", small)
  end

  test "the default work input limit is 256 KiB" do
    %{runtime: runtime, store: store} = start_tasks()
    large = %{"label" => String.duplicate("x", 262_144)}

    assert {:ok, %{"error" => error}} =
             TasksSupport.call(runtime, "default-input", "slow_compute", large)

    assert error["code"] == -32_602
    assert error["message"] == "Task input is larger than 262144 bytes"
    assert :sys.get_state(store).entries == %{}
  end

  test "task IDs over 256 bytes and more than 100 taskIds are refused with -32602" do
    hub = start_supervised!({TasksSubscriptionHub, owner: self()})

    %{runtime: runtime} =
      start_tasks(runtime: [subscription_source: {TasksSubscriptionSource, hub}])

    too_long = String.duplicate("t", 257)
    long_id = %{"code" => -32_602, "message" => "taskId is longer than 256 bytes"}

    assert {:ok, %{"error" => ^long_id}} = TasksSupport.get(runtime, "long-get", too_long)

    assert {:ok, %{"error" => ^long_id}} =
             TasksSupport.update(runtime, "long-update", too_long, %{"answer" => %{}})

    assert {:ok, %{"error" => ^long_id}} =
             TasksSupport.cancel(runtime, "long-cancel", too_long)

    longest = String.duplicate("t", 256)

    assert {:ok, %{"error" => %{"message" => "Unknown or inaccessible taskId"}}} =
             TasksSupport.get(runtime, "longest-get", longest)

    for {id, task_ids, message} <- [
          {"long-listen", [too_long], "taskIds entries must be at most 256 bytes"},
          {"many-listen", Enum.map(1..101, &"task-#{&1}"),
           "taskIds must contain at most 100 entries"}
        ] do
      request =
        TasksSupport.request(id, "subscriptions/listen", %{
          "notifications" => %{"taskIds" => task_ids}
        })

      assert {:ok, %{"error" => %{"code" => -32_602, "message" => ^message}}} =
               TasksSupport.dispatch(runtime, request)
    end

    refute_received {:tasks_subscription_opened, _id, _filter}

    most =
      TasksSupport.request("most-listen", "subscriptions/listen", %{
        "notifications" => %{"taskIds" => [longest | Enum.map(1..99, &"task-#{&1}")]}
      })

    assert {:stream, subscription} = TasksSupport.dispatch(runtime, most)
    assert_receive {:tasks_subscription_opened, "most-listen", %{}}, 1_000
    assert :ok = Snodo.Subscription.close(subscription, :complete)
  end

  test "limit options are validated at startup" do
    store = start_supervised!({Memory, scope: :shared})

    for {key, value} <- [max_jobs: 0, max_jobs: :infinity, max_runtime_ms: 0] do
      opts = [{key, value}, store: {Memory, store}]
      assert_raise ArgumentError, fn -> Runner.init(opts) end
    end

    for {key, value} <- [max_tasks: 0, max_active_tasks_per_scope: -1] do
      assert_raise ArgumentError, fn -> Memory.init([{key, value}, scope: :shared]) end
    end
  end

  defp start_tasks(opts \\ []) do
    store_opts = Keyword.put(Keyword.get(opts, :store, []), :scope, &scope/1)
    store = start_supervised!({Memory, store_opts})
    runner_opts = Keyword.put(Keyword.get(opts, :runner, []), :store, {Memory, store})
    runner = start_supervised!({Runner, runner_opts})

    runtime_opts =
      opts
      |> Keyword.get(:runtime, [])
      |> Keyword.put(:extension_options, Keyword.get(opts, :extension, []))

    %{
      runtime: TasksSupport.runtime(store, runner, self(), runtime_opts),
      runner: runner,
      store: store
    }
  end

  defp create_blocking!(runtime, label, opts \\ []) do
    assert {:ok, %{"result" => %{"taskId" => task_id}}} =
             call_blocking(runtime, label, opts)

    assert_receive {:tasks_barrier_entered, ^label, worker}, 1_000
    {task_id, worker}
  end

  defp call_blocking(runtime, label, opts \\ []) do
    TasksSupport.call(
      runtime,
      "create-#{label}",
      "slow_compute",
      %{"block" => true, "label" => label},
      opts
    )
  end

  defp completed?(task), do: task["status"] == "completed"

  defp awaiting_slot(runner), do: :sys.get_state(runner).awaiting_slot

  defp blocking_work do
    owner = self()

    fn _cancellation ->
      send(owner, {:blocking_work_started, self()})

      receive do
        :finish -> {:completed, %{"finished" => true}}
      end
    end
  end

  defp create_stored!(store, id, opts \\ []) do
    assert {:ok, %Snapshot{} = snapshot} = create_stored(store, id, opts)
    snapshot
  end

  defp create_stored(store, id, opts) do
    task =
      ProtocolTask.new!(
        id: id,
        created_at: @created_at,
        ttl_ms: Keyword.get(opts, :ttl_ms, @ttl_ms),
        poll_interval_ms: 5
      )

    work = Keyword.get_lazy(opts, :work, fn -> Work.new!(id, "limits/test", %{}) end)
    context = Keyword.get(opts, :context, context("tenant"))
    access = authorize!(store, context, {:create, id})
    Store.create(store, task, work, access)
  end

  defp authorize!(store, context, action) do
    assert {:ok, access} = Store.authorize(store, context, action)
    access
  end

  defp dets_options(path, table, clock) do
    [
      path: path,
      table: table,
      clock: clock_fun(clock),
      scope: fn context -> context.auth["tenant"] end,
      max_tasks: 3,
      max_active_tasks_per_scope: 1
    ]
  end

  defp start_dets!(opts) do
    assert {:ok, server} = Dets.start_link(opts)
    server
  end

  defp scope(%Context{auth: %{"tenant" => tenant}}), do: {:tenant, tenant}
  defp scope(%Context{}), do: :shared

  defp context(tenant) do
    %Context{
      protocol_version: V2026_07_28.version(),
      protocol: V2026_07_28,
      transport: %TransportContext{transport: :direct},
      auth: %{"tenant" => tenant}
    }
  end

  defp event!({:ok, %Event{} = event}), do: event

  defp start_clock(initial) do
    start_supervised!({Agent, fn -> initial end}, id: {Agent, make_ref()})
  end

  defp clock_fun(clock), do: fn -> Agent.get(clock, & &1) end

  defp advance_clock(clock, milliseconds) do
    Agent.update(clock, fn current ->
      {:ok, datetime, _offset} = DateTime.from_iso8601(current)

      datetime
      |> DateTime.add(milliseconds, :millisecond)
      |> DateTime.to_iso8601()
    end)
  end

  defp wait_until(condition, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_until(condition, deadline)
  end

  defp do_wait_until(condition, deadline) do
    cond do
      condition.() ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("condition was not met before the deadline")

      true ->
        Process.sleep(5)
        do_wait_until(condition, deadline)
    end
  end

  defp temporary_path(label) do
    path =
      Path.join(
        System.tmp_dir!(),
        "snodo-tasks-#{label}-#{System.pid()}-#{System.unique_integer([:positive])}.dets"
      )

    on_exit(fn -> File.rm(path) end)
    path
  end
end
