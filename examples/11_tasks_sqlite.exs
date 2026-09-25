defmodule Examples.TasksSQLite.Repo do
  @moduledoc false

  use Ecto.Repo,
    otp_app: :snodo_tasks_sqlite,
    adapter: Ecto.Adapters.SQLite3
end

defmodule Examples.TasksSQLite.ExportTool do
  @moduledoc false

  use Snodo.Tool,
    name: "sqlite_export",
    description: "Exports one document through durable SQLite-backed task work"

  @impl true
  def call(_arguments, _context) do
    raise "the application-owned WorkExecutor handles this durable invocation"
  end
end

defmodule Examples.TasksSQLite.Executor do
  @moduledoc false

  @behaviour Snodo.Extensions.Tasks.WorkExecutor

  alias Snodo.Extensions.Tasks.Work

  @impl true
  def execute(
        %Work{
          type: "tools/call",
          input: %{
            "name" => "sqlite_export",
            "arguments" => %{"document" => document}
          }
        } = work,
        _cancellation,
        state
      ) do
    attempt = Agent.get_and_update(state.counter, &{&1 + 1, &1 + 1})
    send(state.owner, {:sqlite_example_execution, attempt, work, self()})

    if attempt == 1 do
      receive do
        {:complete_first_sqlite_attempt, ^document} -> completed(work, document, attempt)
      after
        30_000 -> failed("SQLite example restart did not stop the first worker")
      end
    else
      completed(work, document, attempt)
    end
  end

  def execute(%Work{}, _cancellation, _state),
    do: failed("Unsupported SQLite example work")

  defp completed(work, document, attempt) do
    {:completed,
     %{
       "content" => [
         %{"type" => "text", "text" => "exported #{document} from SQLite work"}
       ],
       "isError" => false,
       "structuredContent" => %{
         "attempt" => attempt,
         "document" => document,
         "idempotencyKey" => work.idempotency_key
       }
     }}
  end

  defp failed(message),
    do: {:failed, %{"code" => -32_603, "message" => message}, message}
end

defmodule Examples.TasksSQLite.Runner do
  @moduledoc false

  alias Examples.TasksSQLite.Executor
  alias Examples.TasksSQLite.ExportTool
  alias Examples.TasksSQLite.Repo
  alias Snodo.Extensions.Tasks
  alias Snodo.Extensions.Tasks.Runner, as: TaskRunner
  alias Snodo.Extensions.Tasks.Store.SQLite
  alias Snodo.Extensions.Tasks.Store.SQLite.Migration
  alias Snodo.Extensions.Tasks.Work
  alias Snodo.Protocol.V2026_07_28
  alias Snodo.Router
  alias Snodo.Server.Runtime

  @migration_version 2_026_082_602
  @protocol "2026-07-28"
  @terminal_statuses ["completed", "failed", "cancelled"]
  @busy_timeout_ms 2_000

  def run(mode) do
    database = unique_database()
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    result =
      try do
        bootstrap_database(database)
        {task_id, first_work} = create_then_stop(database, counter)
        completed = reopen_and_recover(database, counter, task_id, first_work)
        {task_id, completed}
      after
        stop_named_repo()
        stop_process(counter)
        cleanup_database(database)
      end

    Enum.each(
      database_files(database),
      &ensure(not File.exists?(&1), "SQLite file leaked: #{&1}")
    )

    print_result(mode, database, result)
  end

  defp bootstrap_database(database) do
    repo = start_repo!(database, 1)

    try do
      migrate_up!()
    after
      stop_process(repo)
    end
  end

  defp create_then_stop(database, counter) do
    repo = start_repo!(database, 4)
    sqlite = sqlite_config()
    :ok = SQLite.check_schema(sqlite)
    store = {SQLite, sqlite}
    runner = start_runner!(store, counter, "sqlite-example-first-runner")

    try do
      runtime = runtime(store, runner)
      created = call_tool(runtime)
      task_id = get_in(created, ["result", "taskId"])

      ensure(
        get_in(created, ["result", "resultType"]) == "task",
        "task was not created: #{inspect(created)}"
      )

      ensure(is_binary(task_id), "SQLite task id is missing")
      {first_work, first_worker} = await_execution!(1)

      ensure(
        first_work.idempotency_key == task_id,
        "Work did not retain the Task idempotency key"
      )

      ensure(
        first_work.input["arguments"] == %{"document" => "protocol-notes"},
        "Work input changed before persistence"
      )

      ensure(Process.alive?(first_worker), "the first SQLite worker was not running")
      {task_id, first_work}
    after
      stop_process(runner)
      stop_process(repo)
    end
  end

  defp reopen_and_recover(database, counter, task_id, first_work) do
    repo = start_repo!(database, 4)
    sqlite = sqlite_config()
    :ok = SQLite.check_schema(sqlite)
    store = {SQLite, sqlite}
    runner = start_runner!(store, counter, "sqlite-example-recovery-runner")

    try do
      runtime = runtime(store, runner)
      {recovered_work, _worker} = await_execution!(2)

      ensure(recovered_work == first_work, "reopened SQLite changed persisted Work")

      ensure(
        recovered_work.idempotency_key == task_id,
        "recovery changed the stable idempotency key"
      )

      completed = await_terminal(runtime, task_id, monotonic_deadline(5_000))
      ensure(completed["status"] == "completed", "SQLite task did not complete")

      ensure(
        get_in(completed, ["result", "structuredContent", "attempt"]) == 2,
        "replacement Runner did not execute the recovered attempt"
      )

      ensure(
        get_in(completed, ["result", "structuredContent", "idempotencyKey"]) == task_id,
        "terminal result changed the stable idempotency key"
      )

      ensure(
        get_in(completed, ["result", "structuredContent", "document"]) == "protocol-notes",
        "terminal result did not preserve the document"
      )

      completed
    after
      stop_process(runner)
      migrate_down!()
      ensure(adapter_table_count() == 0, "explicit SQLite migration down left adapter tables")
      stop_process(repo)
    end
  end

  defp start_repo!(database, pool_size) do
    {:ok, repo} =
      Repo.start_link(
        database: database,
        pool_size: pool_size,
        journal_mode: :wal,
        foreign_keys: :on,
        busy_timeout: @busy_timeout_ms,
        default_transaction_mode: :deferred,
        log: false
      )

    Process.unlink(repo)
    repo
  end

  defp sqlite_config do
    SQLite.new!(
      repo: Repo,
      scope: fn context -> context.auth["tenant"] end,
      timeout: 5_000
    )
  end

  defp start_runner!(store, counter, owner_id) do
    {:ok, runner} =
      TaskRunner.start_link(
        store: store,
        executor: {Executor, %{counter: counter, owner: self()}},
        recover: true,
        owner_id: owner_id,
        lease_ms: 10_000,
        heartbeat_ms: 3_000,
        recovery_interval_ms: 100
      )

    Process.unlink(runner)
    runner
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
         task_support: %{"sqlite_export" => :required},
         poll_interval_ms: 10}
      ],
      server_info: %{"name" => "tasks-sqlite-example", "version" => "0.1.0"},
      capabilities: %{"tools" => %{}, "extensions" => %{Tasks.id() => %{}}}
    )
  end

  defp call_tool(runtime) do
    dispatch(runtime,
      id: "create-sqlite-task",
      method: "tools/call",
      params: %{
        "name" => "sqlite_export",
        "arguments" => %{"document" => "protocol-notes"}
      }
    )
  end

  defp get_task(runtime, task_id) do
    dispatch(runtime,
      id: "get-sqlite-task-#{System.unique_integer([:positive, :monotonic])}",
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

  defp await_execution!(attempt) do
    receive do
      {:sqlite_example_execution, ^attempt, %Work{} = work, worker} -> {work, worker}
    after
      5_000 -> raise "SQLite WorkExecutor did not start attempt #{attempt}"
    end
  end

  defp await_terminal(runtime, task_id, deadline) do
    response = get_task(runtime, task_id)
    task = response["result"]

    cond do
      is_map(task) and task["status"] in @terminal_statuses ->
        task

      System.monotonic_time(:millisecond) >= deadline ->
        raise "timed out waiting for SQLite task completion"

      true ->
        Process.sleep(10)
        await_terminal(runtime, task_id, deadline)
    end
  end

  defp migrate_up! do
    case Ecto.Migrator.up(Repo, @migration_version, Migration, log: false) do
      :ok -> :ok
      :already_up -> :ok
    end
  end

  defp migrate_down! do
    case Ecto.Migrator.down(Repo, @migration_version, Migration, log: false) do
      :ok -> :ok
      :already_down -> :ok
    end
  end

  defp adapter_table_count do
    %{rows: [[count]]} =
      Ecto.Adapters.SQL.query!(
        Repo,
        "SELECT count(*) FROM sqlite_master " <>
          "WHERE type = 'table' AND name IN " <>
          "('mcp_task_store_metadata', 'mcp_tasks', 'mcp_task_events')",
        [],
        log: false
      )

    count
  end

  defp stop_named_repo do
    case Process.whereis(Repo) do
      nil -> :ok
      repo -> stop_process(repo)
    end
  end

  defp stop_process(process) do
    if is_pid(process) and Process.alive?(process), do: GenServer.stop(process, :normal, 5_000)
    :ok
  end

  defp unique_database do
    Path.join(
      System.tmp_dir!(),
      "snodo_tasks_sqlite_example_#{System.unique_integer([:positive, :monotonic])}.sqlite3"
    )
  end

  defp database_files(database),
    do: [database, database <> "-wal", database <> "-shm", database <> "-journal"]

  defp cleanup_database(database) do
    Enum.each(database_files(database), fn path ->
      case File.rm(path) do
        :ok -> :ok
        {:error, :enoent} -> :ok
        {:error, reason} -> raise "could not remove #{path}: #{inspect(reason)}"
      end
    end)
  end

  defp monotonic_deadline(timeout_ms),
    do: System.monotonic_time(:millisecond) + timeout_ms

  defp ensure(true, _message), do: :ok
  defp ensure(false, message), do: raise(message)

  defp print_result(:check, _database, {_task_id, _completed}),
    do: IO.puts("11_tasks_sqlite: ok")

  defp print_result(:walkthrough, database, {task_id, _completed}) do
    IO.puts("An application-owned Ecto.Repo ran the explicit SQLite Tasks migration.")
    IO.puts("  temporary SQLite file: #{database}")
    IO.puts("  reopened and completed task: #{task_id}")
    IO.puts("  recovery preserved the serialized Work and idempotency key")
    IO.puts("  migration down and exact database-file cleanup completed")
  end
end

case System.argv() do
  ["--check"] -> Examples.TasksSQLite.Runner.run(:check)
  [] -> Examples.TasksSQLite.Runner.run(:walkthrough)
  _arguments -> raise "usage: mix run ../../examples/11_tasks_sqlite.exs [--check]"
end
