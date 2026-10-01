defmodule Examples.TasksClient.Export do
  @moduledoc false

  use Snodo.Tool,
    name: "export",
    description: "Exports a report after the user confirms it"

  alias Snodo.Extensions.Tasks

  @impl true
  def call(%{"report" => report}, context) do
    request = %{
      "method" => "elicitation/create",
      "params" => %{
        "message" => "Export #{report}?",
        "requestedSchema" => %{
          "type" => "object",
          "properties" => %{"confirmed" => %{"type" => "boolean"}},
          "required" => ["confirmed"]
        }
      }
    }

    with {:ok, %{"action" => "accept"}} <- Tasks.await_input(context, "confirm", request) do
      {:ok, Snodo.Result.structured(%{"report" => report, "rows" => 42})}
    end
  end
end

defmodule Examples.TasksClient.Reindex do
  @moduledoc false

  use Snodo.Tool,
    name: "reindex",
    description: "Runs until it is told to finish"

  @impl true
  def call(_arguments, _context) do
    send(Process.whereis(Examples.TasksClient.Runner), {:reindex_started, self()})

    receive do
      :finish -> {:ok, Snodo.Result.text("reindexed")}
    end
  end
end

# A server with the Tasks extension, and a Snodo.Client that calls its tools
# as tasks, answers a task's input request, and cancels a task.
defmodule Examples.TasksClient.Runner do
  @moduledoc false

  alias Examples.TasksClient.Export
  alias Examples.TasksClient.Reindex
  alias Snodo.Client
  alias Snodo.Extensions.Tasks
  alias Snodo.Extensions.Tasks.Client, as: TasksClient
  alias Snodo.Extensions.Tasks.Client.Status
  alias Snodo.Extensions.Tasks.Runner, as: TaskRunner
  alias Snodo.Extensions.Tasks.Store.Memory
  alias Snodo.Protocol.V2026_07_28
  alias Snodo.Router
  alias Snodo.Server.Runtime

  def run(args) do
    check? = check_mode!(args)
    Process.register(self(), __MODULE__)
    {:ok, store} = Memory.start_link(scope: :shared)
    {:ok, runner} = TaskRunner.start_link(store: {Memory, store})

    try do
      {:ok, client} =
        Client.direct(runtime(store, runner), input_handlers: %{form: &confirm/1})

      {:ok, true} = TasksClient.server_supports?(client)
      lines = [export(client), cancel(client)]

      if check?, do: IO.puts("26_tasks_client: ok"), else: Enum.each(lines, &IO.puts/1)
    after
      GenServer.stop(runner)
      GenServer.stop(store)
    end
  end

  # call_tool/4 returns the task; await/3 polls it, answers its input request
  # with the client's form handler, and returns the final tool result.
  defp export(client) do
    {:task, %Status{status: :working} = status} =
      TasksClient.call_tool(client, "export", %{"report" => "q3"})

    {:ok, %{"structuredContent" => %{"report" => "q3", "rows" => 42}}} =
      TasksClient.await(client, status, timeout: 5_000)

    "export: task #{status.task_id} completed after a confirmation"
  end

  defp cancel(client) do
    {:task, status} = TasksClient.call_tool(client, "reindex")

    receive do
      {:reindex_started, _worker} -> :ok
    after
      5_000 -> raise "the reindex task did not start"
    end

    {:ok, %Status{status: :working}} = TasksClient.get(client, status)
    :ok = TasksClient.cancel(client, status)
    {:cancelled, %Status{status: :cancelled}} = TasksClient.await(client, status)
    "reindex: task #{status.task_id} cancelled while working"
  end

  defp confirm(%{"message" => "Export q3?"}),
    do: {:ok, %{"action" => "accept", "content" => %{"confirmed" => true}}}

  defp runtime(store, runner) do
    Runtime.new(
      router: Router.new() |> Router.register_tool(Export) |> Router.register_tool(Reindex),
      protocols: [V2026_07_28],
      extensions: [
        {Tasks,
         store: {Memory, store},
         runner: runner,
         poll_interval_ms: 50,
         task_support: %{"export" => :required, "reindex" => :required}}
      ],
      server_info: %{"name" => "tasks-client-example", "version" => "0.1.0"},
      capabilities: %{"tools" => %{}, "extensions" => %{Tasks.id() => %{}}}
    )
  end

  defp check_mode!([]), do: false
  defp check_mode!(["--check"]), do: true

  defp check_mode!(_arguments),
    do: raise("usage: mix run examples/26_tasks_client.exs [--check]")
end

Examples.TasksClient.Runner.run(System.argv())
