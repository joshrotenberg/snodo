defmodule Examples.TasksSubscriptions.ControlledJob do
  @moduledoc false
  use Snodo.Tool, name: "controlled_job"

  @impl true
  def call(_arguments, _context) do
    owner = Process.whereis(Examples.TasksSubscriptions.Runner)
    send(owner, {:job_started, self()})

    receive do
      :finish -> {:ok, Snodo.Result.text("finished")}
    end
  end
end

defmodule Examples.TasksSubscriptions.Source do
  @moduledoc false
  @behaviour Snodo.Subscription.Source

  alias Snodo.Extensions.Tasks
  alias Snodo.Extensions.Tasks.Snapshot
  alias Snodo.Extensions.Tasks.Store

  @impl true
  def open(filter, context, store) do
    events =
      filter
      |> Map.get("taskIds", [])
      |> Enum.flat_map(&current_event(store, context, &1))

    {:ok, queue} = Agent.start_link(fn -> events end)
    {:ok, filter, queue}
  end

  @impl true
  def next(queue, _store) do
    Agent.get_and_update(queue, fn
      [event | rest] -> {{:ok, event}, rest}
      [] -> {:closed, []}
    end)
  end

  @impl true
  def close(queue, _reason, _store) do
    if Process.alive?(queue), do: Agent.stop(queue)
    :ok
  end

  defp current_event(store, context, task_id) do
    with {:ok, access} <- Store.authorize(store, context, {:get, task_id}),
         {:ok, %Snapshot{} = snapshot} <- Store.get(store, task_id, access) do
      [Tasks.status_event(snapshot.task)]
    else
      _unknown_or_inaccessible -> []
    end
  end
end

defmodule Examples.TasksSubscriptions.Runner do
  @moduledoc false

  alias Examples.TasksSubscriptions.ControlledJob
  alias Examples.TasksSubscriptions.Source
  alias Snodo.Extensions.Tasks
  alias Snodo.Extensions.Tasks.Runner, as: TaskRunner
  alias Snodo.Extensions.Tasks.Store.Memory
  alias Snodo.Protocol.V2026_07_28
  alias Snodo.Router
  alias Snodo.Server.Runtime
  alias Snodo.Subscription

  @protocol "2026-07-28"

  def run(mode) do
    Process.register(self(), __MODULE__)
    {:ok, store} = Memory.start_link()
    store_ref = {Memory, store}
    {:ok, runner} = TaskRunner.start_link(store: store_ref)

    try do
      runtime = runtime(store_ref, runner)
      created = call_task(runtime)
      task_id = get_in(created, ["result", "taskId"])
      ensure(is_binary(task_id), "task creation did not return an id")

      worker =
        receive do
          {:job_started, worker} -> worker
        after
          1_000 -> raise "task worker did not start"
        end

      {:stream, subscription} = listen(runtime, task_id)
      ensure(subscription.accepted_filter == %{"taskIds" => [task_id]}, "filter was not accepted")

      {:ok, acknowledgement} = Subscription.acknowledgement(subscription)
      ensure(acknowledgement["method"] == "notifications/subscriptions/acknowledged", "bad ack")

      {puller, monitor} = Subscription.start_worker(subscription, self())
      :ok = Subscription.continue(puller)

      event =
        receive do
          {:mcp_subscription, ^puller, {:ok, event}} -> event
        after
          1_000 -> raise "subscription did not produce the current task status"
        end

      {:ok, notification} = Subscription.notification(subscription, event)
      ensure(notification["method"] == "notifications/tasks", "wrong notification method")
      ensure(notification["params"]["taskId"] == task_id, "wrong task notification")
      ensure(notification["params"]["status"] == "working", "wrong task status")
      ensure(not Map.has_key?(notification["params"], "resultType"), "leaked response field")

      :ok = Subscription.continue(puller)

      receive do
        {:mcp_subscription, ^puller, :closed} -> :ok
      after
        1_000 -> raise "subscription did not complete"
      end

      {:ok, completion} = Subscription.completion(subscription)
      ensure(get_in(completion, ["result", "resultType"]) == "complete", "bad completion")
      :ok = Subscription.stop_worker(puller, monitor)
      :ok = Subscription.close(subscription, :complete)
      send(worker, :finish)
      print_result(mode, task_id)
    after
      if Process.alive?(runner), do: GenServer.stop(runner)
      if Process.alive?(store), do: GenServer.stop(store)
    end
  end

  defp runtime(store_ref, runner) do
    Runtime.new(
      router: Router.new() |> Router.register_tool(ControlledJob),
      protocols: [V2026_07_28],
      extensions: [
        {Tasks, store: store_ref, runner: runner, task_support: %{"controlled_job" => :required}}
      ],
      subscription_source: {Source, store_ref},
      server_info: %{"name" => "tasks-subscriptions-example", "version" => "1.0.0"},
      capabilities: %{"tools" => %{}, "extensions" => %{Tasks.id() => %{}}}
    )
  end

  defp call_task(runtime) do
    {:ok, response} =
      Snodo.Test.dispatch(runtime,
        id: "create-task",
        protocol: @protocol,
        method: "tools/call",
        params: %{"name" => "controlled_job", "arguments" => %{}},
        client_capabilities: task_capabilities()
      )

    response
  end

  defp listen(runtime, task_id) do
    Snodo.Test.dispatch(runtime,
      id: "listen-task",
      protocol: @protocol,
      method: "subscriptions/listen",
      params: %{"notifications" => %{"taskIds" => [task_id]}},
      client_capabilities: task_capabilities()
    )
  end

  defp task_capabilities, do: %{"extensions" => %{Tasks.id() => %{}}}

  defp ensure(true, _message), do: :ok
  defp ensure(false, message), do: raise(message)

  defp print_result(:check, _task_id), do: IO.puts("17_tasks_subscriptions: ok")

  defp print_result(:walkthrough, task_id) do
    IO.puts("Tasks reused the core subscription lifecycle without entering the core profile.")
    IO.puts("  accepted task: #{task_id}")
    IO.puts("  event: notifications/tasks (complete working snapshot)")
  end
end

case System.argv() do
  ["--check"] -> Examples.TasksSubscriptions.Runner.run(:check)
  [] -> Examples.TasksSubscriptions.Runner.run(:walkthrough)
  _arguments -> raise "usage: mix run examples/17_tasks_subscriptions.exs [--check]"
end
