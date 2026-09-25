defmodule Examples.TasksPostgres.Repo do
  @moduledoc false

  use Ecto.Repo,
    otp_app: :snodo_tasks_postgres,
    adapter: Ecto.Adapters.Postgres
end

defmodule Examples.TasksPostgres.ExportTool do
  @moduledoc false

  use Snodo.Tool,
    name: "postgres_export",
    description: "Exports one document through durable PostgreSQL-backed task work"

  @impl true
  def call(_arguments, _context) do
    raise "the application-owned WorkExecutor handles this durable invocation"
  end
end

defmodule Examples.TasksPostgres.Executor do
  @moduledoc false

  @behaviour Snodo.Extensions.Tasks.WorkExecutor

  alias Snodo.Extensions.Tasks.Work

  @impl true
  def execute(
        %Work{
          type: "tools/call",
          input: %{
            "name" => "postgres_export",
            "arguments" => %{"document" => document}
          }
        } = work,
        _cancellation,
        owner
      ) do
    send(owner, {:postgres_example_execution, work, self()})

    receive do
      {:complete_postgres_example, ^document} ->
        {:completed,
         %{
           "content" => [
             %{"type" => "text", "text" => "exported #{document} from PostgreSQL work"}
           ],
           "isError" => false,
           "structuredContent" => %{
             "document" => document,
             "idempotencyKey" => work.idempotency_key
           }
         }}
    after
      5_000 ->
        {:failed, %{"code" => -32_603, "message" => "PostgreSQL example coordination timed out"},
         "PostgreSQL example coordination timed out"}
    end
  end

  def execute(%Work{}, _cancellation, _owner) do
    {:failed, %{"code" => -32_603, "message" => "Unsupported PostgreSQL example work"},
     "Unsupported PostgreSQL example work"}
  end
end

defmodule Examples.TasksPostgres.Runner do
  @moduledoc false

  alias Examples.TasksPostgres.Executor
  alias Examples.TasksPostgres.ExportTool
  alias Examples.TasksPostgres.Repo
  alias Snodo.Extensions.Tasks
  alias Snodo.Extensions.Tasks.Runner, as: TaskRunner
  alias Snodo.Extensions.Tasks.Store.Postgres
  alias Snodo.Extensions.Tasks.Store.Postgres.Migration
  alias Snodo.Extensions.Tasks.Work
  alias Snodo.Protocol.V2026_07_28
  alias Snodo.Router
  alias Snodo.Server.Runtime

  @migration_version 2_026_082_502
  @protocol "2026-07-28"
  @terminal_statuses ["completed", "failed", "cancelled"]

  def run(mode) do
    database_url = database_url!()
    schema = unique_schema()
    {:ok, repo} = Repo.start_link(url: database_url, pool_size: 4, log: false)
    Process.unlink(repo)

    try do
      create_schema!(schema)

      try do
        migrate_up!(schema)
        run_task(mode, schema)
      after
        drop_schema!(schema)
      end
    after
      stop_process(repo)
    end
  end

  defp run_task(mode, schema) do
    postgres =
      Postgres.new!(
        repo: Repo,
        prefix: schema,
        scope: fn context -> context.auth["tenant"] end,
        timeout: 5_000,
        lock_timeout_ms: 2_000
      )

    :ok = Postgres.check_schema(postgres)
    store = {Postgres, postgres}

    {:ok, runner} =
      TaskRunner.start_link(
        store: store,
        executor: {Executor, self()},
        recover: true,
        owner_id: "postgres-example-runner",
        lease_ms: 10_000,
        heartbeat_ms: 3_000,
        recovery_interval_ms: 100
      )

    try do
      runtime = runtime(store, runner)
      created = call_tool(runtime)
      task_id = get_in(created, ["result", "taskId"])

      ensure(
        get_in(created, ["result", "resultType"]) == "task",
        "task was not created: #{inspect(created)}"
      )

      ensure(is_binary(task_id), "PostgreSQL task id is missing")

      {work, worker} = await_execution!()

      ensure(work.idempotency_key == task_id, "Work did not retain the Task idempotency key")
      ensure(work.input["arguments"] == %{"document" => "protocol-notes"}, "Work changed")

      send_execution_completion(worker, work)
      completed = await_terminal(runtime, task_id, monotonic_deadline(5_000))

      ensure(completed["status"] == "completed", "PostgreSQL task did not complete")

      ensure(
        get_in(completed, ["result", "structuredContent", "idempotencyKey"]) == task_id,
        "terminal result changed the stable idempotency key"
      )

      ensure(
        get_in(completed, ["result", "structuredContent", "document"]) == "protocol-notes",
        "terminal result did not preserve the document"
      )

      print_result(mode, task_id, schema)
    after
      stop_process(runner)
    end
  end

  defp runtime(store, runner) do
    router = Router.new() |> Router.register_tool(ExportTool)

    Runtime.new(
      router: router,
      protocols: [V2026_07_28],
      extensions: [
        {Tasks,
         store: store,
         runner: runner,
         task_support: %{"postgres_export" => :required},
         poll_interval_ms: 10}
      ],
      server_info: %{"name" => "tasks-postgres-example", "version" => "0.1.0"},
      capabilities: %{"tools" => %{}, "extensions" => %{Tasks.id() => %{}}}
    )
  end

  defp call_tool(runtime) do
    dispatch(runtime,
      id: "create-postgres-task",
      method: "tools/call",
      params: %{
        "name" => "postgres_export",
        "arguments" => %{"document" => "protocol-notes"}
      }
    )
  end

  defp get_task(runtime, task_id) do
    dispatch(runtime,
      id: "get-postgres-task-#{System.unique_integer([:positive, :monotonic])}",
      method: "tasks/get",
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
        client_capabilities: %{"extensions" => %{Tasks.id() => %{}}},
        transport_metadata: %{auth: %{"tenant" => "example-tenant"}}
      )

    response
  end

  defp await_execution! do
    receive do
      {:postgres_example_execution, %Work{} = work, worker} ->
        {work, worker}
    after
      5_000 -> raise "the PostgreSQL WorkExecutor did not start"
    end
  end

  defp send_execution_completion(
         worker,
         %Work{input: %{"arguments" => %{"document" => document}}}
       ) do
    send(worker, {:complete_postgres_example, document})
  end

  defp await_terminal(runtime, task_id, deadline) do
    response = get_task(runtime, task_id)
    task = response["result"]

    cond do
      is_map(task) and task["status"] in @terminal_statuses ->
        task

      System.monotonic_time(:millisecond) >= deadline ->
        raise "timed out waiting for PostgreSQL task completion"

      true ->
        Process.sleep(10)
        await_terminal(runtime, task_id, deadline)
    end
  end

  defp migrate_up!(schema) do
    case Ecto.Migrator.up(Repo, @migration_version, Migration, prefix: schema, log: false) do
      :ok -> :ok
      :already_up -> :ok
    end
  end

  defp create_schema!(schema),
    do: query!("CREATE SCHEMA #{quote_identifier(schema)}")

  defp drop_schema!(schema),
    do: query!("DROP SCHEMA IF EXISTS #{quote_identifier(schema)} CASCADE")

  defp query!(sql), do: Ecto.Adapters.SQL.query!(Repo, sql, [], log: false)

  defp quote_identifier(identifier),
    do: "\"" <> String.replace(identifier, "\"", "\"\"") <> "\""

  defp unique_schema do
    "mcp_tasks_example_#{System.system_time(:microsecond)}_#{System.unique_integer([:positive])}"
  end

  defp database_url! do
    case System.get_env("SNODO_TASKS_DATABASE_URL") do
      url when is_binary(url) and url != "" ->
        url

      _missing ->
        raise """
        SNODO_TASKS_DATABASE_URL is required for example 10; for example:
        ecto://postgres:postgres@127.0.0.1:55432/snodo_tasks
        """
    end
  end

  defp monotonic_deadline(timeout_ms),
    do: System.monotonic_time(:millisecond) + timeout_ms

  defp stop_process(process) do
    if is_pid(process) and Process.alive?(process), do: GenServer.stop(process, :normal, 5_000)
  end

  defp ensure(true, _message), do: :ok
  defp ensure(false, message), do: raise(message)

  defp print_result(:check, _task_id, _schema), do: IO.puts("10_tasks_postgres: ok")

  defp print_result(:walkthrough, task_id, schema) do
    IO.puts("An application-owned Ecto.Repo ran the explicit Tasks migration.")
    IO.puts("  temporary PostgreSQL schema: #{schema}")
    IO.puts("  completed task: #{task_id}")
    IO.puts("  the Runner used persisted Work through an application WorkExecutor")
    IO.puts("  the exact temporary schema and Repo are removed on exit")
  end
end

case System.argv() do
  ["--check"] -> Examples.TasksPostgres.Runner.run(:check)
  [] -> Examples.TasksPostgres.Runner.run(:walkthrough)
  _arguments -> raise "usage: mix run ../../examples/10_tasks_postgres.exs [--check]"
end
