defmodule Snodo.TasksHTTPAcceptanceTest do
  use ExUnit.Case, async: false

  @moduletag mcp_contract: ["tasks-extension-http-admission"]
  @moduletag :tasks_package

  alias Snodo.Extensions.Tasks
  alias Snodo.Extensions.Tasks.Runner
  alias Snodo.Extensions.Tasks.Store.Memory
  alias Snodo.Subscription
  alias Snodo.Transport.StreamableHTTP
  alias Snodo.Transport.StreamableHTTP.Request
  alias Snodo.Transport.StreamableHTTP.StreamResponse
  alias SnodoTest.TasksSubscriptionHub
  alias SnodoTest.TasksSubscriptionSource
  alias SnodoTest.TasksTestSupport, as: TasksSupport

  @protocol "2026-07-28"

  setup do
    store = start_supervised!(Memory)
    runner = start_supervised!({Runner, store: {Memory, store}})

    %{runtime: TasksSupport.runtime(store, runner, self())}
  end

  test "all task methods require Mcp-Name mirrored from params.taskId", %{runtime: runtime} do
    for {method, params} <- [
          {"tasks/get", %{"taskId" => "unknown-task"}},
          {"tasks/update", %{"taskId" => "unknown-task", "inputResponses" => %{}}},
          {"tasks/cancel", %{"taskId" => "unknown-task"}}
        ] do
      raw = TasksSupport.request("http-#{method}", method, params)

      missing = StreamableHTTP.handle(runtime, request(raw, base_headers(method)))
      assert missing.status == 400
      assert get_in(JSON.decode!(missing.body), ["error", "code"]) == -32_020

      mismatched =
        StreamableHTTP.handle(
          runtime,
          request(raw, [{"Mcp-Name", "another-task"} | base_headers(method)])
        )

      assert mismatched.status == 400
      assert get_in(JSON.decode!(mismatched.body), ["error", "code"]) == -32_020

      admitted =
        StreamableHTTP.handle(
          runtime,
          request(raw, [{"Mcp-Name", "unknown-task"} | base_headers(method)])
        )

      assert admitted.status == 400
      assert get_in(JSON.decode!(admitted.body), ["error", "code"]) == -32_602
    end
  end

  test "task-id routing accepts the standard base64 sentinel", %{runtime: runtime} do
    task_id = "task/with unicode ✓"
    raw = TasksSupport.request("http-encoded-task", "tasks/get", %{"taskId" => task_id})
    encoded = "=?base64?#{Base.encode64(task_id)}?="

    response =
      StreamableHTTP.handle(
        runtime,
        request(raw, [{"Mcp-Name", encoded} | base_headers("tasks/get")])
      )

    assert response.status == 400
    assert get_in(JSON.decode!(response.body), ["error", "code"]) == -32_602
  end

  @tag mcp_contract: ["tasks-extension-subscriptions-http"]
  test "HTTP admits taskIds and returns the shared long-lived SSE descriptor", %{
    runtime: _runtime
  } do
    store = start_supervised!(Memory, id: :tasks_http_subscription_store)

    runner =
      start_supervised!({Runner, store: {Memory, store}}, id: :tasks_http_subscription_runner)

    hub = start_supervised!({TasksSubscriptionHub, owner: self()})

    runtime =
      TasksSupport.runtime(store, runner, self(),
        subscription_source: {TasksSubscriptionSource, hub}
      )

    assert {:ok, %{"result" => created}} =
             TasksSupport.call(runtime, "http-sub-create", "slow_compute", %{"label" => "http"})

    task_id = created["taskId"]

    raw =
      TasksSupport.request("http-tasks-sub", "subscriptions/listen", %{
        "notifications" => %{"taskIds" => [task_id]}
      })

    response = StreamableHTTP.handle(runtime, request(raw, base_headers("subscriptions/listen")))
    assert %StreamResponse{status: 200, subscription: subscription} = response
    assert {"content-type", "text/event-stream"} in response.headers
    assert_receive {:tasks_subscription_opened, "http-tasks-sub", %{"taskIds" => [^task_id]}}

    state = :sys.get_state(store)
    task = state.entries[task_id].snapshot.task
    assert {:ok, notification} = Subscription.notification(subscription, Tasks.status_event(task))
    assert notification["method"] == "notifications/tasks"
    assert notification["params"]["taskId"] == task_id

    assert :ok = Subscription.close(subscription, :disconnected)
    assert_receive {:tasks_subscription_closed, "http-tasks-sub", :disconnected}
  end

  defp request(raw, headers) do
    %Request{
      method: "POST",
      path: "/mcp",
      headers: headers,
      body: JSON.encode!(raw),
      peer: {{127, 0, 0, 1}, 50_000},
      connection_ref: make_ref()
    }
  end

  defp base_headers(method) do
    [
      {"Content-Type", "application/json; charset=utf-8"},
      {"Accept", "application/json, text/event-stream"},
      {"MCP-Protocol-Version", @protocol},
      {"Mcp-Method", method}
    ]
  end
end
