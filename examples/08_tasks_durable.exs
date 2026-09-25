defmodule Examples.TasksDurable.ExportTool do
  @moduledoc false

  use Snodo.Tool,
    name: "durable_export",
    description: "Exports one document through durable task execution"

  alias Snodo.Extensions.Tasks

  @impl true
  def call(%{"document" => document}, context) do
    principal = %{"tenant" => context.auth["tenant"]}
    execution_id = Tasks.execution_id(context) || "synchronous"
    {:ok, result(document, principal, execution_id)}
  end

  def result(document, principal, execution_id) do
    Snodo.Result.structured(%{
      "document" => document,
      "tenant" => principal["tenant"],
      "idempotencyKey" => execution_id
    })
  end
end

defmodule Examples.TasksDurable.WorkBuilder do
  @moduledoc false

  alias Snodo.Extensions.Tasks.Work

  def build(task_id, tool_name, arguments, context) do
    Work.new(task_id, "example/durable-tool-call", %{
      "tool" => tool_name,
      "arguments" => arguments,
      "principal" => %{"tenant" => context.auth["tenant"]}
    })
  end
end

defmodule Examples.TasksDurable.Executor do
  @moduledoc false

  @behaviour Snodo.Extensions.Tasks.WorkExecutor

  alias Examples.TasksDurable.ExportTool
  alias Snodo.Cancellation
  alias Snodo.Context
  alias Snodo.Extensions.Tasks.Work
  alias Snodo.Protocol.V2026_07_28
  alias Snodo.Transport.Context, as: TransportContext

  @impl true
  def execute(
        %Work{type: "example/durable-tool-call"} = work,
        cancellation,
        %{owner: owner}
      ) do
    send(owner, {:durable_execution_started, work, self()})

    receive do
      {:finish_durable_execution, execution_id}
      when execution_id == work.idempotency_key ->
        complete(work, cancellation)
    after
      10_000 ->
        {:failed, %{"code" => -32_603, "message" => "Durable example execution timed out"},
         "Durable example execution timed out"}
    end
  end

  def execute(%Work{}, _cancellation, _state) do
    {:failed, %{"code" => -32_603, "message" => "Unsupported durable example work"},
     "Unsupported durable example work"}
  end

  defp complete(work, cancellation) do
    if Cancellation.cancelled?(cancellation) do
      {:failed, %{"code" => -32_603, "message" => "Durable example execution was cancelled"},
       "Durable example execution was cancelled"}
    else
      input = work.input
      arguments = input["arguments"]
      principal = input["principal"]

      result =
        ExportTool.result(
          arguments["document"],
          principal,
          work.idempotency_key
        )

      {:completed,
       V2026_07_28.shape_result(
         {:tools_call, input["tool"]},
         result,
         execution_context(principal)
       )}
    end
  end

  defp execution_context(principal) do
    %Context{
      protocol_version: V2026_07_28.version(),
      protocol: V2026_07_28,
      transport: %TransportContext{transport: :task},
      auth: principal,
      server_capabilities: %{"tools" => %{}}
    }
  end
end

defmodule Examples.TasksDurable.Runner do
  @moduledoc false

  alias Examples.TasksDurable.Executor
  alias Examples.TasksDurable.ExportTool
  alias Examples.TasksDurable.WorkBuilder
  alias Snodo.Extensions.Tasks
  alias Snodo.Extensions.Tasks.Runner, as: TaskRunner
  alias Snodo.Extensions.Tasks.Store.Dets
  alias Snodo.Protocol.V2026_07_28
  alias Snodo.Router
  alias Snodo.Server.Runtime

  @protocol "2026-07-28"
  @table :snodo_tasks_durable_example
  @terminal_statuses ["completed", "failed", "cancelled"]

  def run(mode) do
    directory = unique_directory!()
    path = Path.join(directory, "tasks.dets")

    try do
      run_recovery(mode, path)
    after
      cleanup_directory!(directory)
    end
  end

  defp run_recovery(mode, path) do
    {:ok, first_store} = start_store(path)
    first_store_ref = {Dets, first_store}
    {:ok, first_runner} = start_runner(first_store_ref, "durable-example-first")

    try do
      runtime = runtime(first_store_ref, first_runner)
      capabilities = %{"extensions" => %{Tasks.id() => %{}}}
      auth = request_auth()

      created = call_tool(runtime, "create-durable", auth, capabilities)
      task_id = get_in(created, ["result", "taskId"])

      ensure(get_in(created, ["result", "resultType"]) == "task", "task was not created")
      ensure(is_binary(task_id), "durable task id is missing")

      first_work = await_execution!(task_id)
      assert_safe_projection!(first_work, task_id)

      stop_process(first_store)
      stop_process(first_runner)

      recover(mode, path, task_id, first_work, capabilities)
    after
      stop_process(first_store)
      stop_process(first_runner)
    end
  end

  defp recover(mode, path, task_id, first_work, capabilities) do
    {:ok, recovered_store} = start_store(path)
    recovered_ref = {Dets, recovered_store}
    {:ok, recovered_runner} = start_runner(recovered_ref, "durable-example-recovered")

    try do
      recovered_work = await_execution!(task_id)

      ensure(recovered_work == first_work, "recovery changed the persisted descriptor")

      ensure(
        recovered_work.idempotency_key == task_id,
        "recovery changed the idempotency key"
      )

      send(self_for(recovered_work), {:finish_durable_execution, task_id})

      recovered_runtime = runtime(recovered_ref, recovered_runner)

      completed =
        await_terminal(
          recovered_runtime,
          task_id,
          request_auth(),
          capabilities
        )

      ensure(completed["status"] == "completed", "recovered task did not complete")

      ensure(
        get_in(completed, ["result", "structuredContent"]) == %{
          "document" => "quarterly-report",
          "tenant" => "tenant-a",
          "idempotencyKey" => task_id
        },
        "recovered result did not preserve work identity and tenant projection"
      )

      print_result(mode, task_id)
    after
      stop_process(recovered_runner)
      stop_process(recovered_store)
    end
  end

  defp start_store(path) do
    case Dets.start_link(
           path: path,
           table: @table,
           scope: fn context -> context.auth["tenant"] end
         ) do
      {:ok, store} = started ->
        Process.unlink(store)
        started

      other ->
        other
    end
  end

  defp start_runner(store_ref, owner_id) do
    case TaskRunner.start_link(
           store: store_ref,
           executor: {Executor, %{owner: self()}},
           recover: true,
           owner_id: owner_id,
           lease_ms: 30_000,
           heartbeat_ms: 20_000,
           recovery_interval_ms: 60_000
         ) do
      {:ok, runner} = started ->
        Process.unlink(runner)
        started

      other ->
        other
    end
  end

  defp runtime(store_ref, runner) do
    router = Router.new() |> Router.register_tool(ExportTool)

    Runtime.new(
      router: router,
      protocols: [V2026_07_28],
      extensions: [
        {Tasks,
         store: store_ref,
         runner: runner,
         work_builder: &WorkBuilder.build/4,
         task_support: %{"durable_export" => :required},
         ttl_ms: 60_000,
         poll_interval_ms: 5}
      ],
      server_info: %{"name" => "tasks-durable-example", "version" => "0.1.0"},
      capabilities: %{"tools" => %{}, "extensions" => %{Tasks.id() => %{}}}
    )
  end

  defp call_tool(runtime, id, auth, client_capabilities) do
    dispatch(runtime,
      id: id,
      method: "tools/call",
      auth: auth,
      client_capabilities: client_capabilities,
      params: %{
        "name" => "durable_export",
        "arguments" => %{"document" => "quarterly-report"}
      }
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

  defp dispatch(runtime, opts) do
    {:ok, response} =
      Snodo.Test.dispatch(runtime,
        id: Keyword.fetch!(opts, :id),
        protocol: @protocol,
        method: Keyword.fetch!(opts, :method),
        params: Keyword.fetch!(opts, :params),
        client_capabilities: Keyword.fetch!(opts, :client_capabilities),
        transport_metadata: %{auth: Keyword.fetch!(opts, :auth)}
      )

    response
  end

  defp await_execution!(task_id) do
    receive do
      {:durable_execution_started, work, worker} ->
        ensure(work.idempotency_key == task_id, "executor received the wrong task")
        Process.put({__MODULE__, task_id}, worker)
        work
    after
      1_000 -> raise "durable task execution did not start"
    end
  end

  defp self_for(work) do
    Process.get({__MODULE__, work.idempotency_key}) ||
      raise "durable task worker identity was not recorded"
  end

  defp assert_safe_projection!(work, task_id) do
    ensure(work.idempotency_key == task_id, "descriptor idempotency key differs from task id")
    ensure(work.input["principal"] == %{"tenant" => "tenant-a"}, "tenant was not projected")

    ensure(
      not Map.has_key?(work.input["principal"], "requestOnly"),
      "request-only authority leaked into durable work"
    )
  end

  defp await_terminal(runtime, task_id, auth, capabilities, attempts \\ 100)

  defp await_terminal(_runtime, task_id, _auth, _capabilities, 0) do
    raise "task #{task_id} did not reach a terminal state"
  end

  defp await_terminal(runtime, task_id, auth, capabilities, attempts) do
    response = get_task(runtime, "poll-#{attempts}", task_id, auth, capabilities)
    task = response["result"]

    if task["status"] in @terminal_statuses do
      task
    else
      receive do
      after
        2 -> :ok
      end

      await_terminal(runtime, task_id, auth, capabilities, attempts - 1)
    end
  end

  defp request_auth do
    %{
      "tenant" => "tenant-a",
      "requestOnly" => make_ref()
    }
  end

  defp unique_directory! do
    suffix = System.unique_integer([:positive, :monotonic])
    directory = Path.join(System.tmp_dir!(), "snodo_tasks_durable_#{suffix}")
    File.mkdir!(directory)
    directory
  end

  defp cleanup_directory!(directory) do
    case File.ls(directory) do
      {:ok, entries} ->
        Enum.each(entries, fn entry -> File.rm!(Path.join(directory, entry)) end)
        File.rmdir!(directory)

      {:error, :enoent} ->
        :ok
    end
  end

  defp stop_process(process) when is_pid(process) do
    if Process.alive?(process), do: GenServer.stop(process, :normal, 5_000)
    :ok
  end

  defp ensure(true, _message), do: :ok
  defp ensure(false, message), do: raise(message)

  defp print_result(:check, _task_id), do: IO.puts("08_tasks_durable: ok")

  defp print_result(:walkthrough, task_id) do
    IO.puts("DETS recovered one descriptor-bearing Task after a store and runner restart.")
    IO.puts("  recovered task: #{task_id}")
    IO.puts("  idempotency key remained stable across two execution attempts")
    IO.puts("  DETS is a local single-node reference; recovery is at-least-once")
  end
end

case System.argv() do
  ["--check"] -> Examples.TasksDurable.Runner.run(:check)
  [] -> Examples.TasksDurable.Runner.run(:walkthrough)
  _arguments -> raise "usage: mix run examples/08_tasks_durable.exs [--check]"
end
