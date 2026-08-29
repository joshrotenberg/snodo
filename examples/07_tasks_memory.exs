defmodule Examples.TasksMemory.ControlledJob do
  @moduledoc false

  use MCP.Tool,
    name: "controlled_job",
    description: "Runs as an application-owned task with explicit coordination"

  @impl true
  def call(%{"token" => token}, context) do
    owner = :global.whereis_name({__MODULE__, token})
    send(owner, {:controlled_job_entered, token, self(), context.auth})

    receive do
      {:finish, ^token} ->
        send(owner, {:controlled_job_returning, token, self()})
        {:ok, MCP.Result.text("finished #{token}")}
    end
  end
end

defmodule Examples.TasksMemory.Runner do
  @moduledoc false

  alias Examples.TasksMemory.ControlledJob
  alias MCP.Extensions.Tasks
  alias MCP.Extensions.Tasks.Runner, as: TaskRunner
  alias MCP.Extensions.Tasks.Store.Memory
  alias MCP.Protocol.V2026_07_28
  alias MCP.Router
  alias MCP.Server.Runtime

  @protocol "2026-07-28"
  @terminal_statuses ["completed", "failed", "cancelled"]
  @terminal_wait_ms 10_000

  def run(mode) do
    {:ok, store} = Memory.start_link(scope: & &1.auth)
    store_ref = {Memory, store}
    {:ok, runner} = TaskRunner.start_link(store: store_ref)

    try do
      runtime = runtime(store_ref, runner)
      capabilities = %{"extensions" => %{Tasks.id() => %{}}}

      missing = call_tool(runtime, "missing-capability", "required", :tenant_a, %{})

      ensure(
        get_in(missing, ["error", "code"]) == -32_021,
        "a required task tool must reject a request without the extension"
      )

      first = register_token("complete")
      created = call_tool(runtime, "create-complete", first, :tenant_a, capabilities)
      task_id = get_in(created, ["result", "taskId"])

      ensure(get_in(created, ["result", "resultType"]) == "task", "task was not created")
      ensure(is_binary(task_id), "task id is missing")

      receive do
        {:controlled_job_entered, ^first, worker, :tenant_a} ->
          working = get_task(runtime, "get-working", task_id, :tenant_a, capabilities)
          ensure(get_in(working, ["result", "status"]) == "working", "task is not working")

          isolated = get_task(runtime, "get-isolated", task_id, :tenant_b, capabilities)

          ensure(
            get_in(isolated, ["error", "code"]) == -32_602,
            "a different authorization scope must not see the task"
          )

          send(worker, {:finish, first})
      after
        1_000 -> raise "the first task worker did not start"
      end

      receive do
        {:controlled_job_returning, ^first, _worker} -> :ok
      after
        1_000 -> raise "the first task worker did not finish"
      end

      completed = await_terminal(runtime, task_id, :tenant_a, capabilities)
      ensure(completed["status"] == "completed", "the first task did not complete")

      ensure(
        get_in(completed, ["result", "content", Access.at(0), "text"]) == "finished complete",
        "the completed task did not inline its original tool result"
      )

      :global.unregister_name({ControlledJob, first})
      second = register_token("cancel")
      cancel_created = call_tool(runtime, "create-cancel", second, :tenant_a, capabilities)
      cancel_id = get_in(cancel_created, ["result", "taskId"])

      receive do
        {:controlled_job_entered, ^second, _worker, :tenant_a} -> :ok
      after
        1_000 -> raise "the cancellable task worker did not start"
      end

      cancel_ack = cancel_task(runtime, cancel_id, :tenant_a, capabilities)
      ensure(ack?(cancel_ack["result"]), "cancel did not return an empty ack")

      cancelled = get_task(runtime, "get-cancelled", cancel_id, :tenant_a, capabilities)

      ensure(
        get_in(cancelled, ["result", "status"]) == "cancelled",
        "cancelled task was not terminal"
      )

      print_result(mode, task_id, cancel_id)
    after
      :global.unregister_name({ControlledJob, "complete"})
      :global.unregister_name({ControlledJob, "cancel"})
      if Process.alive?(runner), do: GenServer.stop(runner)
      if Process.alive?(store), do: GenServer.stop(store)
    end
  end

  defp runtime(store_ref, runner) do
    router = Router.new() |> Router.register_tool(ControlledJob)

    Runtime.new(
      router: router,
      protocols: [V2026_07_28],
      extensions: [
        {Tasks,
         store: store_ref,
         runner: runner,
         task_support: %{"controlled_job" => :required},
         poll_interval_ms: 10}
      ],
      server_info: %{"name" => "tasks-memory-example", "version" => "0.1.0"},
      capabilities: %{"tools" => %{}, "extensions" => %{Tasks.id() => %{}}}
    )
  end

  defp call_tool(runtime, id, token, auth, client_capabilities) do
    dispatch(runtime,
      id: id,
      method: "tools/call",
      auth: auth,
      client_capabilities: client_capabilities,
      params: %{"name" => "controlled_job", "arguments" => %{"token" => token}}
    )
  end

  defp get_task(runtime, id, task_id, auth, client_capabilities) do
    dispatch(runtime,
      id: id,
      method: "tasks/get",
      auth: auth,
      client_capabilities: client_capabilities,
      params: %{"taskId" => task_id}
    )
  end

  defp cancel_task(runtime, task_id, auth, client_capabilities) do
    dispatch(runtime,
      id: "cancel-task",
      method: "tasks/cancel",
      auth: auth,
      client_capabilities: client_capabilities,
      params: %{"taskId" => task_id}
    )
  end

  defp dispatch(runtime, opts) do
    {:ok, response} =
      MCP.Test.dispatch(runtime,
        id: Keyword.fetch!(opts, :id),
        protocol: @protocol,
        method: Keyword.fetch!(opts, :method),
        params: Keyword.fetch!(opts, :params),
        client_capabilities: Keyword.fetch!(opts, :client_capabilities),
        transport_metadata: %{auth: Keyword.fetch!(opts, :auth)}
      )

    response
  end

  defp await_terminal(runtime, task_id, auth, capabilities) do
    deadline = System.monotonic_time(:millisecond) + @terminal_wait_ms
    await_terminal(runtime, task_id, auth, capabilities, deadline)
  end

  defp await_terminal(runtime, task_id, auth, capabilities, deadline) do
    response = get_task(runtime, "poll-#{System.unique_integer()}", task_id, auth, capabilities)
    task = response["result"]

    if task["status"] in @terminal_statuses do
      task
    else
      if System.monotonic_time(:millisecond) >= deadline do
        raise "task did not reach a terminal state; last response: #{inspect(response)}"
      else
        Process.sleep(1)
        await_terminal(runtime, task_id, auth, capabilities, deadline)
      end
    end
  end

  defp register_token(token) do
    :yes = :global.register_name({ControlledJob, token}, self())
    token
  end

  defp ack?(%{"resultType" => "complete"} = ack) do
    Enum.all?(["taskId", "status", "result", "error", "inputRequests"], fn key ->
      not Map.has_key?(ack, key)
    end)
  end

  defp ack?(_other), do: false

  defp ensure(true, _message), do: :ok
  defp ensure(false, message), do: raise(message)

  defp print_result(:check, _task_id, _cancel_id), do: IO.puts("07_tasks_memory: ok")

  defp print_result(:walkthrough, task_id, cancel_id) do
    IO.puts("Tasks remained an exact-versioned extension outside the core catalog.")
    IO.puts("  completed task: #{task_id}")
    IO.puts("  cancelled task: #{cancel_id}")
    IO.puts("  store visibility was bound to the request authorization scope")
  end
end

case System.argv() do
  ["--check"] -> Examples.TasksMemory.Runner.run(:check)
  [] -> Examples.TasksMemory.Runner.run(:walkthrough)
  _arguments -> raise "usage: mix run examples/07_tasks_memory.exs [--check]"
end
