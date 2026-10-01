defmodule Snodo.Extensions.Tasks.ClientTest do
  use ExUnit.Case, async: true

  @moduletag :tasks_package
  @moduletag timeout: 60_000

  alias Snodo.Client
  alias Snodo.Error
  alias Snodo.Extensions.Tasks
  alias Snodo.Extensions.Tasks.Client, as: TasksClient
  alias Snodo.Extensions.Tasks.Client.Status
  alias Snodo.Extensions.Tasks.Runner
  alias Snodo.Extensions.Tasks.Store.Memory
  alias Snodo.Extensions.Tasks.Task, as: ProtocolTask
  alias Snodo.Protocol.V2026_07_28
  alias Snodo.Router
  alias Snodo.Server.Runtime
  alias Snodo.Transport.StreamableHTTP.Server, as: HTTPServer
  alias SnodoTest.TasksSubscriptionHub
  alias SnodoTest.TasksSubscriptionSource
  alias SnodoTest.TasksTestSupport, as: TasksSupport

  @fixture Path.expand("fixtures/tasks_client_stdio_server.exs", __DIR__)

  defp start_server(opts \\ []) do
    {scope, opts} = Keyword.pop(opts, :scope, :shared)
    store = start_supervised!({Memory, scope: scope})
    runner = start_supervised!({Runner, store: {Memory, store}})
    %{store: store, runtime: TasksSupport.runtime(store, runner, self(), opts)}
  end

  defp direct(runtime, opts \\ []) do
    {:ok, client} = Client.direct(runtime, opts)
    client
  end

  # A store scope that tells `test` of each tasks/get as the store authorizes
  # it. Every request gets the same scope.
  defp report_gets(test) do
    fn context ->
      if context.request_method == "tasks/get",
        do: send(test, {:get, System.monotonic_time(:millisecond)})

      :shared
    end
  end

  defp accept(_params), do: {:ok, %{"action" => "accept", "content" => %{"confirmed" => true}}}

  defp barrier(label) do
    assert_receive {:tasks_barrier_entered, ^label, worker}, 5_000
    worker
  end

  describe "negotiation" do
    test "capabilities/1 adds the extension with empty settings" do
      assert TasksClient.capabilities() == %{"extensions" => %{Tasks.id() => %{}}}

      assert TasksClient.capabilities(%{
               "elicitation" => %{"form" => %{}},
               "extensions" => %{"example.com/other" => %{"a" => 1}}
             }) == %{
               "elicitation" => %{"form" => %{}},
               "extensions" => %{"example.com/other" => %{"a" => 1}, Tasks.id() => %{}}
             }
    end

    test "server_supports?/1 reads the server's advertised extensions" do
      %{runtime: runtime} = start_server()
      assert {:ok, true} = TasksClient.server_supports?(direct(runtime))

      plain =
        Runtime.new(
          router: Router.new(),
          protocols: [V2026_07_28],
          server_info: %{"name" => "plain", "version" => "0.1.0"},
          capabilities: %{"tools" => %{}}
        )

      assert {:ok, false} = TasksClient.server_supports?(direct(plain))
    end

    test "each call declares the extension; the client's other calls do not" do
      %{runtime: runtime} = start_server()
      client = direct(runtime)

      assert {:ok, %{"structuredContent" => %{"label" => "sync"}}} =
               Client.call_tool(client, "slow_compute", %{"label" => "sync"})

      assert {:error, %Error{code: -32_021}} = Client.call_tool(client, "failing_job")

      assert {:task, %Status{status: :working, task_id: "task-" <> _id}} =
               TasksClient.call_tool(client, "slow_compute", %{"label" => "task"})

      assert {:task, %Status{}} = TasksClient.call_tool(client, "failing_job")
    end

    test "a client built with capabilities/1 declares the extension on every request" do
      %{runtime: runtime} = start_server()
      client = direct(runtime, client_capabilities: TasksClient.capabilities())

      assert {:ok, %{"resultType" => "task", "taskId" => task_id}} =
               Client.call_tool(client, "slow_compute", %{"label" => "declared"})

      assert {:ok, %{"structuredContent" => %{"label" => "declared"}}} =
               TasksClient.await(client, task_id, timeout: 5_000)
    end
  end

  describe "calling a tool" do
    test "a tool the server runs synchronously returns its result" do
      %{runtime: runtime} = start_server()

      assert {:ok, %{"content" => [%{"text" => "Hello, Ada!"}]}} =
               TasksClient.call_tool(direct(runtime), "greet", %{"name" => "Ada"})

      assert {:ok, %{"content" => [%{"text" => "Hello, Ada!"}]}} =
               TasksClient.call_and_await(direct(runtime), "greet", %{"name" => "Ada"})
    end

    test "the creation result decodes into a status" do
      %{runtime: runtime} = start_server()

      assert {:task, status} =
               TasksClient.call_tool(direct(runtime), "slow_compute", %{"label" => "fields"})

      assert %Status{
               status: :working,
               status_message: "Task accepted",
               ttl_ms: 60_000,
               poll_interval_ms: 5,
               input_requests: %{},
               result: nil,
               error: nil,
               raw: %{"resultType" => "task"}
             } = status

      assert is_binary(status.created_at) and is_binary(status.last_updated_at)
    end

    test "call_and_await returns the final tool result" do
      %{runtime: runtime} = start_server()

      assert {:ok, %{"structuredContent" => %{"label" => "done", "computed" => true}}} =
               TasksClient.call_and_await(direct(runtime), "slow_compute", %{"label" => "done"})
    end

    test "a tool-domain error completes the task with an isError result" do
      %{runtime: runtime} = start_server()

      assert {:ok, %{"isError" => true}} =
               TasksClient.call_and_await(direct(runtime), "failing_job")
    end

    test "a failed task returns its JSON-RPC error with the status in cause" do
      %{runtime: runtime} = start_server()

      assert {:error, %Error{code: -32_603, kind: :execution, cause: {:task_failed, status}}} =
               TasksClient.call_and_await(direct(runtime), "protocol_error_job")

      assert %Status{status: :failed, error: %{"code" => -32_603}} = status
    end
  end

  describe "task methods" do
    test "get/3 reads the task and an unknown task is -32602" do
      %{runtime: runtime} = start_server()
      client = direct(runtime)

      {:task, created} =
        TasksClient.call_tool(client, "slow_compute", %{"label" => "get", "block" => true})

      worker = barrier("get")
      assert {:ok, %Status{task_id: id, status: :working}} = TasksClient.get(client, created)
      assert id == created.task_id
      send(worker, {:tasks_release, "get"})

      assert {:error, %Error{code: -32_602}} = TasksClient.get(client, "no-such-task")
    end

    test "cancel/3 cancels a running task" do
      %{runtime: runtime} = start_server()
      client = direct(runtime)

      {:task, status} =
        TasksClient.call_tool(client, "slow_compute", %{"label" => "cancel", "block" => true})

      _worker = barrier("cancel")
      assert :ok = TasksClient.cancel(client, status)
      assert {:cancelled, %Status{status: :cancelled}} = TasksClient.await(client, status)
      assert :ok = TasksClient.cancel(client, status.task_id)
      assert {:error, %Error{code: -32_602}} = TasksClient.cancel(client, "no-such-task")
    end

    test "update/4 answers an input request by hand" do
      %{runtime: runtime} = start_server()
      client = direct(runtime)

      assert {:input_required, %Status{input_requests: requests} = status} =
               TasksClient.call_and_await(client, "confirm_delete", %{}, [], timeout: 5_000)

      assert %{"confirmation" => %{"method" => "elicitation/create"}} = requests
      response = %{"action" => "accept", "content" => %{"confirmed" => true}}
      assert :ok = TasksClient.update(client, status, %{"confirmation" => response})

      assert {:ok, %{"structuredContent" => %{"confirmation" => ^response}}} =
               TasksClient.await(client, status, timeout: 5_000)
    end
  end

  describe "waiting" do
    test "the client's input handlers answer a task's input requests" do
      %{runtime: runtime} = start_server()
      test = self()

      client =
        direct(runtime,
          input_handlers: %{
            form: fn params ->
              send(test, {:asked, params["message"]})
              accept(params)
            end
          }
        )

      assert {:ok, %{"structuredContent" => %{"confirmation" => %{"action" => "accept"}}}} =
               TasksClient.call_and_await(client, "confirm_delete", %{}, [], timeout: 5_000)

      assert_received {:asked, "Confirm delete"}
    end

    test "input: :return leaves the requests to the caller even with handlers installed" do
      %{runtime: runtime} = start_server()
      client = direct(runtime, input_handlers: %{form: &accept/1})

      assert {:input_required, %Status{input_requests: %{"confirmation" => _request}}} =
               TasksClient.call_and_await(client, "confirm_delete", %{}, [], input: :return)
    end

    test "a function answers the outstanding requests" do
      %{runtime: runtime} = start_server()
      test = self()

      answer = fn %Status{input_requests: requests} ->
        send(test, {:requests, Map.keys(requests)})
        {:ok, Map.new(requests, fn {key, _request} -> {key, %{"action" => "accept"}} end)}
      end

      assert {:ok, %{"structuredContent" => %{"responses" => responses}}} =
               TasksClient.call_and_await(direct(runtime), "multi_input", %{}, [],
                 input: answer,
                 timeout: 5_000
               )

      assert responses == %{
               "first" => %{"action" => "accept"},
               "second" => %{"action" => "accept"}
             }

      assert_received {:requests, _keys}
    end

    test "a handler error stops the wait" do
      %{runtime: runtime} = start_server()
      client = direct(runtime, input_handlers: %{form: fn _params -> {:error, :declined} end})

      assert {:error, %Error{code: -32_603, cause: cause}} =
               TasksClient.call_and_await(client, "confirm_delete", %{}, [], timeout: 5_000)

      assert {:input_handler, "confirmation", :declined, %Status{status: :input_required}} = cause
    end

    test "a request with no handler for its kind is returned to the caller" do
      %{runtime: runtime} = start_server()
      client = direct(runtime, input_handlers: %{url: fn _params -> {:ok, %{}} end})

      assert {:input_required, %Status{}} =
               TasksClient.call_and_await(client, "confirm_delete", %{}, [], timeout: 5_000)
    end

    test "the wait is bounded and leaves the task running" do
      %{runtime: runtime} = start_server()
      client = direct(runtime)

      {:task, status} =
        TasksClient.call_tool(client, "slow_compute", %{"label" => "slow", "block" => true})

      worker = barrier("slow")

      assert {:error, %Error{code: -32_001, kind: :transport, data: data, cause: cause}} =
               TasksClient.await(client, status, timeout: 100)

      assert data == %{"taskId" => status.task_id, "timeoutMs" => 100}
      assert {:timeout, %Status{status: :working}} = cause

      send(worker, {:tasks_release, "slow"})

      assert {:ok, %{"structuredContent" => %{"label" => "slow"}}} =
               TasksClient.await(client, status.task_id, timeout: 5_000)
    end

    test "polling waits the task's pollIntervalMs" do
      %{runtime: runtime} =
        start_server(scope: report_gets(self()), extension_options: [poll_interval_ms: 300])

      client = direct(runtime)

      {:task, status} =
        TasksClient.call_tool(client, "slow_compute", %{"label" => "paced", "block" => true})

      worker = barrier("paced")
      waiter = Task.async(fn -> TasksClient.await(client, status, timeout: 5_000) end)

      assert_receive {:get, first}, 5_000
      assert_receive {:get, second}, 5_000
      assert second - first >= 300

      send(worker, {:tasks_release, "paced"})
      assert {:ok, _result} = Task.await(waiter, 5_000)
    end

    test "listen: true against a server without a subscription source is -32601" do
      %{runtime: runtime} = start_server()
      client = direct(runtime)
      {:task, status} = TasksClient.call_tool(client, "slow_compute", %{"label" => "nosource"})

      assert {:error, %Error{code: -32_601}} =
               TasksClient.await(client, status, listen: true, timeout: 1_000)
    end

    test "invalid options raise" do
      %{runtime: runtime} = start_server()
      client = direct(runtime)

      assert_raise ArgumentError, fn -> TasksClient.await(client, "t", timeout: 0) end
      assert_raise ArgumentError, fn -> TasksClient.await(client, "t", input: :ask) end
      assert_raise ArgumentError, fn -> TasksClient.await(client, "t", listen: :yes) end
      assert_raise ArgumentError, fn -> TasksClient.await(client, "t", poll_interval: -1) end
      assert_raise ArgumentError, fn -> TasksClient.get(client, "") end
    end
  end

  describe "waiting on a subscriptions/listen stream" do
    # Unless a test sets :poll_interval_ms, the poll interval is far past the
    # wait's timeout, so only a notification can finish the wait in time.
    setup ctx do
      hub = start_supervised!({TasksSubscriptionHub, owner: self()})

      scope = if ctx[:report_gets], do: report_gets(self()), else: :shared

      server =
        start_server(
          scope: scope,
          subscription_source: {TasksSubscriptionSource, hub},
          extension_options: [poll_interval_ms: Map.get(ctx, :poll_interval_ms, 600_000)]
        )

      Map.put(server, :hub, hub)
    end

    test "a notifications/tasks event finishes the wait", %{store: store} = ctx do
      client = direct(ctx.runtime)

      {:task, status} =
        TasksClient.call_tool(client, "slow_compute", %{"label" => "listen", "block" => true})

      worker = barrier("listen")

      waiter =
        Task.async(fn -> TasksClient.await(client, status, listen: true, timeout: 5_000) end)

      task_id = status.task_id
      assert_receive {:tasks_subscription_opened, request_id, %{"taskIds" => [^task_id]}}, 5_000

      # The worker stays blocked, so tasks/get reads :working throughout and
      # only this event, queued until the waiter asks for it, completes the wait.
      task = :sys.get_state(store).entries[task_id].snapshot.task
      result = %{"content" => [], "structuredContent" => %{"via" => "notification"}}
      {:ok, completed} = ProtocolTask.complete(task, result, ProtocolTask.timestamp())
      assert :ok = TasksSubscriptionHub.emit(ctx.hub, request_id, Tasks.status_event(completed))

      assert {:ok, ^result} = Task.await(waiter, 5_000)
      assert_receive {:tasks_subscription_closed, ^request_id, _reason}, 5_000
      send(worker, {:tasks_release, "listen"})
    end

    @tag poll_interval_ms: 5
    @tag report_gets: true
    test "a stream that ends first is followed by polling", %{runtime: runtime, hub: hub} do
      client = direct(runtime)

      {:task, status} =
        TasksClient.call_tool(client, "slow_compute", %{"label" => "ended", "block" => true})

      worker = barrier("ended")

      waiter =
        Task.async(fn -> TasksClient.await(client, status, listen: true, timeout: 5_000) end)

      task_id = status.task_id
      assert_receive {:tasks_subscription_opened, request_id, %{"taskIds" => [^task_id]}}, 5_000
      assert :ok = TasksSubscriptionHub.complete(hub, request_id)
      # The waiter reads the task once the stream is acknowledged, while the
      # worker is still blocked; the release can only be seen by a poll.
      assert_receive {:get, _at}, 5_000
      send(worker, {:tasks_release, "ended"})

      assert {:ok, %{"structuredContent" => %{"label" => "ended"}}} = Task.await(waiter, 5_000)
    end

    test "an unknown task is refused", %{runtime: runtime} do
      assert {:error, %Error{code: -32_602}} =
               TasksClient.await(direct(runtime), "no-such-task", listen: true, timeout: 1_000)
    end
  end

  describe "over stdio" do
    setup do
      elixir = System.find_executable("elixir")
      core = Snodo.Client |> :code.which() |> List.to_string() |> Path.dirname()
      tasks = Path.expand(Mix.Project.compile_path())

      {:ok, client} =
        Client.connect({:stdio, elixir, ["-pa", core, "-pa", tasks, @fixture]},
          input_handlers: %{form: &accept/1}
        )

      on_exit(fn -> Client.close(client) end)
      %{client: client}
    end

    test "calls, waits, answers input, and reads failures", %{client: client} do
      assert {:ok, true} = TasksClient.server_supports?(client)

      assert {:ok, %{"structuredContent" => %{"label" => "stdio"}}} =
               TasksClient.call_and_await(client, "slow_compute", %{"label" => "stdio"}, [],
                 timeout: 10_000
               )

      assert {:ok, %{"structuredContent" => %{"confirmation" => %{"action" => "accept"}}}} =
               TasksClient.call_and_await(client, "confirm_delete", %{}, [], timeout: 10_000)

      assert {:error, %Error{code: -32_603, cause: {:task_failed, %Status{}}}} =
               TasksClient.call_and_await(client, "protocol_error_job", %{}, [], timeout: 10_000)

      assert {:error, %Error{code: -32_602}} = TasksClient.get(client, "no-such-task")
    end

    test "waits on a stream that sends the current status", %{client: client} do
      {:task, status} = TasksClient.call_tool(client, "slow_compute", %{"label" => "streamed"})

      assert {:ok, %{"structuredContent" => %{"label" => "streamed"}}} =
               TasksClient.await(client, status, listen: true, timeout: 10_000)

      assert :ok = TasksClient.cancel(client, status)
    end
  end

  describe "over Streamable HTTP" do
    test "creates a task; the task methods lack the Mcp-Name header the server requires" do
      %{runtime: runtime} = start_server()
      listener = start_supervised!({HTTPServer, runtime: runtime, port: 0})
      {:ok, client} = Client.connect({:http, HTTPServer.url(listener)})

      assert {:task, %Status{} = status} =
               TasksClient.call_tool(client, "slow_compute", %{"label" => "http"})

      assert {:error, %Error{code: -32_020}} = TasksClient.get(client, status)
    end
  end
end
