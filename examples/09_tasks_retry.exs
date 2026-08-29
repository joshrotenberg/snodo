defmodule Examples.TasksRetry.FlakyExport do
  @moduledoc false

  use MCP.Tool,
    name: "flaky_export",
    description: "A durable export whose application executor requests one retry"

  @impl true
  def call(_arguments, _context) do
    raise "the configured WorkExecutor owns durable execution"
  end
end

defmodule Examples.TasksRetry.Executor do
  @moduledoc false

  @behaviour MCP.Extensions.Tasks.WorkExecutor

  alias MCP.Extensions.Tasks.Work

  @impl true
  def execute(%Work{type: "tools/call"} = work, _cancellation, state) do
    attempt = Agent.get_and_update(state.attempts, &{&1 + 1, &1 + 1})
    send(state.owner, {:retry_example_execution, attempt, work})

    case attempt do
      1 ->
        {:retry,
         %{
           "code" => -32_603,
           "message" => "Export service is temporarily unavailable",
           "data" => %{"attempt" => attempt}
         }, "Export will retry"}

      2 ->
        {:completed,
         %{
           "content" => [%{"type" => "text", "text" => "export complete"}],
           "isError" => false,
           "structuredContent" => %{
             "attempt" => attempt,
             "document" => work.input["arguments"]["document"],
             "idempotencyKey" => work.idempotency_key
           }
         }}
    end
  end

  def execute(%Work{}, _cancellation, _state) do
    {:failed, %{"code" => -32_603, "message" => "Unsupported retry example work"},
     "Unsupported retry example work"}
  end
end

defmodule Examples.TasksRetry.Runner do
  @moduledoc false

  alias Examples.TasksRetry.Executor
  alias Examples.TasksRetry.FlakyExport
  alias MCP.Context
  alias MCP.Extensions.Tasks
  alias MCP.Extensions.Tasks.RetryPolicy
  alias MCP.Extensions.Tasks.Runner, as: TaskRunner
  alias MCP.Extensions.Tasks.Snapshot
  alias MCP.Extensions.Tasks.Store
  alias MCP.Extensions.Tasks.Store.Memory
  alias MCP.Protocol.V2026_07_28
  alias MCP.Router
  alias MCP.Server.Runtime
  alias MCP.Transport.Context, as: TransportContext

  @protocol "2026-07-28"
  @created_at "2026-08-25T10:00:00.000Z"
  @retry_delay_ms 60_000

  def run(mode) do
    owner = self()
    {:ok, clock} = Agent.start_link(fn -> @created_at end)
    {:ok, attempts} = Agent.start_link(fn -> 0 end)

    {:ok, store} =
      Memory.start_link(
        clock: fn ->
          now = Agent.get(clock, & &1)
          send(owner, {:retry_example_clock_read, now})
          now
        end
      )

    store_ref = {Memory, store}
    {:ok, first_runner} = start_runner(store_ref, attempts, "retry-example-first")

    try do
      run_retry(mode, clock, attempts, store_ref, first_runner)
    after
      stop_process(first_runner)
      stop_process(store)
      stop_process(attempts)
      stop_process(clock)
    end
  end

  defp run_retry(mode, clock, attempts, store_ref, first_runner) do
    policy = RetryPolicy.new!([@retry_delay_ms])
    runtime = runtime(store_ref, first_runner, policy)
    created = call_tool(runtime, "create-retry")
    task_id = get_in(created, ["result", "taskId"])

    ensure(get_in(created, ["result", "resultType"]) == "task", "task was not created")
    ensure(is_binary(task_id), "retry task id is missing")

    first_work = await_execution!(task_id, 1)
    scheduled = await_snapshot!(store_ref, task_id, &(&1.retry_count == 1))

    ensure(first_work.retry_policy == policy, "retry policy was not persisted with work")
    ensure(scheduled.work == first_work, "scheduled work changed after execution")
    ensure(scheduled.retry_at == "2026-08-25T10:01:00.001Z", "retry time is wrong")

    stop_process(first_runner)
    drain_clock_reads()
    run_replacement(mode, clock, attempts, store_ref, task_id, first_work, scheduled)
  end

  defp run_replacement(mode, clock, attempts, store_ref, task_id, first_work, scheduled) do
    {:ok, replacement} = start_runner(store_ref, attempts, "retry-example-replacement")

    try do
      await_clock_read!(@created_at)

      ensure(
        Store.claim(store_ref, task_id, "early-probe", 30_000) == {:deferred, 60_001},
        "store allowed retry before authoritative time"
      )

      ensure(Agent.get(attempts, & &1) == 1, "replacement executed retry too early")
      Agent.update(clock, fn _current -> scheduled.retry_at end)

      second_work = await_execution!(task_id, 2)
      ensure(second_work == first_work, "replacement received different work")
      ensure(second_work.idempotency_key == task_id, "idempotency key changed on retry")

      completed = await_snapshot!(store_ref, task_id, &(&1.task.status == :completed))
      result = completed.task.result["structuredContent"]

      ensure(result["attempt"] == 2, "retry did not complete on its second execution")
      ensure(result["idempotencyKey"] == task_id, "completed result changed work identity")
      ensure(completed.retry_count == 1, "retry budget was consumed incorrectly")
      ensure(completed.retry_at == nil, "terminal task retained retry availability")
      ensure(Agent.get(attempts, & &1) == 2, "executor ran an unexpected number of times")

      print_result(mode, task_id, scheduled.retry_at)
    after
      stop_process(replacement)
    end
  end

  defp start_runner(store_ref, attempts, owner_id) do
    case TaskRunner.start_link(
           store: store_ref,
           executor: {Executor, %{owner: self(), attempts: attempts}},
           recover: true,
           owner_id: owner_id,
           lease_ms: 30_000,
           heartbeat_ms: 20_000,
           recovery_interval_ms: 5
         ) do
      {:ok, runner} = started ->
        Process.unlink(runner)
        started

      other ->
        other
    end
  end

  defp runtime(store_ref, runner, retry_policy) do
    router = Router.new() |> Router.register_tool(FlakyExport)

    Runtime.new(
      router: router,
      protocols: [V2026_07_28],
      extensions: [
        {Tasks,
         store: store_ref,
         runner: runner,
         retry_policy: retry_policy,
         task_support: %{"flaky_export" => :required},
         clock: fn -> @created_at end,
         ttl_ms: 300_000,
         poll_interval_ms: 5}
      ],
      server_info: %{"name" => "tasks-retry-example", "version" => "0.1.0"},
      capabilities: %{"tools" => %{}, "extensions" => %{Tasks.id() => %{}}}
    )
  end

  defp call_tool(runtime, id) do
    {:ok, response} =
      MCP.Test.dispatch(runtime,
        id: id,
        protocol: @protocol,
        method: "tools/call",
        params: %{
          "name" => "flaky_export",
          "arguments" => %{"document" => "retry-report"}
        },
        client_capabilities: %{"extensions" => %{Tasks.id() => %{}}}
      )

    response
  end

  defp await_execution!(task_id, attempt) do
    receive do
      {:retry_example_execution, ^attempt, work} ->
        ensure(work.idempotency_key == task_id, "executor received the wrong task identity")
        work
    after
      1_000 -> raise "retry execution #{attempt} did not start"
    end
  end

  defp await_clock_read!(expected) do
    receive do
      {:retry_example_clock_read, ^expected} -> :ok
    after
      1_000 -> raise "replacement Runner did not consult the authoritative clock"
    end
  end

  defp drain_clock_reads do
    receive do
      {:retry_example_clock_read, _now} -> drain_clock_reads()
    after
      0 -> :ok
    end
  end

  defp await_snapshot!(store_ref, task_id, predicate, attempts \\ 100)

  defp await_snapshot!(_store_ref, task_id, _predicate, 0) do
    raise "task #{task_id} did not reach the expected persisted state"
  end

  defp await_snapshot!(store_ref, task_id, predicate, attempts) do
    snapshot = snapshot!(store_ref, task_id)

    if predicate.(snapshot) do
      snapshot
    else
      await_snapshot!(store_ref, task_id, predicate, attempts - 1)
    end
  end

  defp snapshot!(store_ref, task_id) do
    {:ok, access} = Store.authorize(store_ref, context(), {:get, task_id})
    {:ok, %Snapshot{} = snapshot} = Store.get(store_ref, task_id, access)
    snapshot
  end

  defp context do
    %Context{
      protocol_version: V2026_07_28.version(),
      protocol: V2026_07_28,
      transport: %TransportContext{transport: :direct}
    }
  end

  defp stop_process(process) when is_pid(process) do
    if Process.alive?(process), do: GenServer.stop(process, :normal, 5_000)
    :ok
  end

  defp ensure(true, _message), do: :ok
  defp ensure(false, message), do: raise(message)

  defp print_result(:check, _task_id, _retry_at), do: IO.puts("09_tasks_retry: ok")

  defp print_result(:walkthrough, task_id, retry_at) do
    IO.puts("A replacement Runner honored one persisted application retry.")
    IO.puts("  task and idempotency key: #{task_id}")
    IO.puts("  store-authoritative retry time: #{retry_at}")
    IO.puts("  no early execution; completed on attempt 2 after the fake clock advanced")
  end
end

case System.argv() do
  ["--check"] -> Examples.TasksRetry.Runner.run(:check)
  [] -> Examples.TasksRetry.Runner.run(:walkthrough)
  _arguments -> raise "usage: mix run examples/09_tasks_retry.exs [--check]"
end
