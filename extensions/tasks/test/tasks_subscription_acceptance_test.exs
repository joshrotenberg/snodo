defmodule MCP.TasksSubscriptionAcceptanceTest do
  use ExUnit.Case, async: false

  @moduletag mcp_contract: ["tasks-extension-subscriptions"]
  @moduletag :tasks_package

  alias MCP.Extensions.Tasks
  alias MCP.Extensions.Tasks.Runner
  alias MCP.Extensions.Tasks.Store.Memory
  alias MCP.Subscription
  alias MCP.Subscription.Event
  alias MCP.Transport.Stdio
  alias MCPEx.TasksSubscriptionHub
  alias MCPEx.TasksSubscriptionSource
  alias MCPEx.TasksTestInput
  alias MCPEx.TasksTestSupport, as: TasksSupport

  @subscription_id_key "io.modelcontextprotocol/subscriptionId"

  setup do
    store = start_supervised!(Memory)
    runner = start_supervised!({Runner, store: {Memory, store}})
    hub = start_supervised!({TasksSubscriptionHub, owner: self()})

    runtime =
      TasksSupport.runtime(store, runner, self(),
        subscription_source: {TasksSubscriptionSource, hub},
        tools_list_changed: true
      )

    %{hub: hub, runtime: runtime, store: store}
  end

  test "Tasks contributes authorized taskIds beside core filters and shapes full status events",
       %{
         hub: hub,
         runtime: runtime,
         store: store
       } do
    {task_id, task, worker} = create_working_task(runtime, store, "direct-subscription")

    request =
      TasksSupport.request("tasks-direct-sub", "subscriptions/listen", %{
        "notifications" => %{
          "toolsListChanged" => true,
          "taskIds" => [task_id, "unknown-task", task_id]
        }
      })

    assert {:stream, subscription} = TasksSupport.dispatch(runtime, request)

    accepted = %{"toolsListChanged" => true, "taskIds" => [task_id]}
    assert_receive {:tasks_subscription_opened, "tasks-direct-sub", ^accepted}
    assert subscription.accepted_filter == accepted
    assert subscription.extension_filters == %{Tasks.id() => %{"taskIds" => [task_id]}}

    assert {:ok, acknowledgement} = Subscription.acknowledgement(subscription)
    assert get_in(acknowledgement, ["params", "notifications"]) == accepted

    event = Tasks.status_event(task, metadata: %{"com.example/revision" => 0})
    assert {:ok, notification} = Subscription.notification(subscription, event)

    assert notification["method"] == "notifications/tasks"
    assert notification["params"]["taskId"] == task_id
    assert notification["params"]["status"] == "working"
    refute Map.has_key?(notification["params"], "resultType")

    assert notification["params"]["_meta"] == %{
             "com.example/revision" => 0,
             @subscription_id_key => "tasks-direct-sub"
           }

    assert :drop =
             Subscription.notification(
               subscription,
               Tasks.status_event(%{task | id: "another-task"})
             )

    smuggled =
      Event.extension(
        Tasks.id(),
        %{"taskIds" => [task_id]},
        %{task | id: "another-task"}
      )

    assert {:error, %MCP.Error{code: -32_603}} =
             Subscription.notification(subscription, smuggled)

    assert {:ok, core_notification} =
             Subscription.notification(subscription, Event.tools_list_changed())

    assert core_notification["method"] == "notifications/tools/list_changed"

    assert :ok = Subscription.close(subscription, :complete)
    assert_receive {:tasks_subscription_closed, "tasks-direct-sub", :complete}
    send(worker, {:tasks_release, "direct-subscription"})
    assert Process.alive?(hub)
  end

  test "taskIds requires peer negotiation and rejects malformed values before opening", %{
    runtime: runtime,
    store: store
  } do
    {task_id, _task, worker} = create_working_task(runtime, store, "missing-capability")

    missing =
      TasksSupport.request(
        "tasks-missing-capability",
        "subscriptions/listen",
        %{"notifications" => %{"taskIds" => [task_id]}},
        tasks: false
      )

    assert {:ok,
            %{
              "error" => %{
                "code" => -32_021,
                "data" => %{
                  "requiredCapabilities" => %{
                    "extensions" => %{"io.modelcontextprotocol/tasks" => %{}}
                  }
                }
              }
            }} = TasksSupport.dispatch(runtime, missing)

    for invalid <- ["not-a-list", [""], [123]] do
      request =
        TasksSupport.request("tasks-invalid-filter", "subscriptions/listen", %{
          "notifications" => %{"taskIds" => invalid}
        })

      assert {:ok, %{"error" => %{"code" => -32_602}}} =
               TasksSupport.dispatch(runtime, request)
    end

    refute_receive {:tasks_subscription_opened, _, _}
    send(worker, {:tasks_release, "missing-capability"})
  end

  test "inaccessible task IDs are omitted without disclosing their existence" do
    scope = fn context -> get_in(context.auth || %{}, ["tenant"]) || :anonymous end
    store = start_supervised!({Memory, scope: scope}, id: :scoped_subscription_store)
    runner = start_supervised!({Runner, store: {Memory, store}}, id: :scoped_subscription_runner)
    hub = start_supervised!({TasksSubscriptionHub, owner: self()}, id: :scoped_subscription_hub)

    runtime =
      TasksSupport.runtime(store, runner, self(),
        subscription_source: {TasksSubscriptionSource, hub}
      )

    assert {:ok, %{"result" => created}} =
             TasksSupport.call(
               runtime,
               "tenant-a-create",
               "slow_compute",
               %{"block" => true, "label" => "tenant-a"},
               auth: %{"tenant" => "a"}
             )

    assert_receive {:tasks_barrier_entered, "tenant-a", worker}
    task_id = created["taskId"]

    request =
      TasksSupport.request("tenant-b-listen", "subscriptions/listen", %{
        "notifications" => %{"taskIds" => [task_id]}
      })

    assert {:stream, subscription} =
             TasksSupport.dispatch(runtime, request, auth: %{"tenant" => "b"})

    assert_receive {:tasks_subscription_opened, "tenant-b-listen", %{}}
    assert subscription.accepted_filter == %{}
    assert subscription.extension_filters == %{}

    task = task_from_store(store, task_id)
    assert :drop = Subscription.notification(subscription, Tasks.status_event(task))

    assert :ok = Subscription.close(subscription, :complete)
    send(worker, {:tasks_release, "tenant-a"})
  end

  test "stdio carries Tasks events and cancellation through the shared stream lifecycle", %{
    hub: hub,
    runtime: runtime,
    store: store
  } do
    {task_id, task, worker} = create_working_task(runtime, store, "stdio-subscription")
    {:ok, input} = TasksTestInput.start_link()
    {:ok, output} = StringIO.open("")
    server = Task.async(fn -> Stdio.serve(runtime, input: input, output: output) end)

    listen =
      TasksSupport.request("tasks-stdio-sub", "subscriptions/listen", %{
        "notifications" => %{"taskIds" => [task_id]}
      })

    TasksTestInput.push(input, JSON.encode!(listen) <> "\n")
    assert_receive {:tasks_subscription_opened, "tasks-stdio-sub", %{"taskIds" => [^task_id]}}

    assert [%{"method" => "notifications/subscriptions/acknowledged"}] =
             await_output_messages(output, 1)

    assert :ok = TasksSubscriptionHub.emit(hub, "tasks-stdio-sub", Tasks.status_event(task))
    [acknowledgement, notification] = await_output_messages(output, 2)
    assert acknowledgement["method"] == "notifications/subscriptions/acknowledged"
    assert notification["method"] == "notifications/tasks"
    assert notification["params"]["taskId"] == task_id

    cancellation = %{
      "jsonrpc" => "2.0",
      "method" => "notifications/cancelled",
      "params" => %{"requestId" => "tasks-stdio-sub", "reason" => "done observing"}
    }

    TasksTestInput.push(input, JSON.encode!(cancellation) <> "\n")

    assert_receive {:tasks_subscription_closed, "tasks-stdio-sub", {:cancelled, "done observing"}}

    TasksTestInput.eof(input)
    assert :ok = Task.await(server, 1_000)
    assert length(await_output_messages(output, 2)) == 2
    send(worker, {:tasks_release, "stdio-subscription"})
  end

  defp create_working_task(runtime, store, label) do
    assert {:ok, %{"result" => created}} =
             TasksSupport.call(runtime, "create-#{label}", "slow_compute", %{
               "block" => true,
               "label" => label
             })

    assert_receive {:tasks_barrier_entered, ^label, worker}
    task_id = created["taskId"]
    task = task_from_store(store, task_id)
    {task_id, task, worker}
  end

  defp task_from_store(store, task_id) do
    state = :sys.get_state(store)
    state.entries[task_id].snapshot.task
  end

  defp await_output_messages(output, count, attempts \\ 100)

  defp await_output_messages(output, count, attempts) when attempts > 0 do
    {_remaining_input, raw_output} = StringIO.contents(output)

    messages =
      raw_output
      |> String.split("\n", trim: true)
      |> Enum.map(&JSON.decode!/1)

    if length(messages) >= count do
      messages
    else
      Process.sleep(10)
      await_output_messages(output, count, attempts - 1)
    end
  end

  defp await_output_messages(_output, count, 0) do
    flunk("timed out waiting for #{count} stdio messages")
  end
end
