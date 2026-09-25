defmodule Snodo.SubscriptionHubTest do
  use ExUnit.Case, async: true

  alias Snodo.Subscription
  alias Snodo.Subscription.Event
  alias Snodo.Subscription.Hub
  alias Snodo.Test, as: MCPTest
  alias SnodoTest.TestFixtures
  alias SnodoTest.TestInstrumentationSink

  test "broadcasts only to matching listeners and supplies pending pulls" do
    {:ok, hub} = start_supervised({Hub, max_buffer: 2})
    runtime = runtime(hub)

    tools = listen(runtime, "tools", %{"toolsListChanged" => true})

    resource =
      listen(runtime, "resource", %{"resourceSubscriptions" => ["test://resource/one"]})

    {tools_worker, tools_monitor} = Subscription.start_worker(tools, self())
    {resource_worker, resource_monitor} = Subscription.start_worker(resource, self())
    :ok = Subscription.continue(tools_worker)
    :ok = Subscription.continue(resource_worker)

    assert {:ok, tools_report} = Hub.notify_tools_list_changed(hub)
    assert %{matched: 1, dropped: 0} = tools_report
    assert tools_report.delivered + tools_report.buffered == 1

    assert_receive {:mcp_subscription, ^tools_worker, {:ok, %Event{kind: :tools_list_changed}}}
    refute_receive {:mcp_subscription, ^resource_worker, _outcome}, 20

    assert {:ok, resource_report} =
             Hub.notify_resource_updated(hub, "test://resource/one")

    assert %{matched: 1, dropped: 0} = resource_report
    assert resource_report.delivered + resource_report.buffered == 1

    assert_receive {:mcp_subscription, ^resource_worker,
                    {:ok, %Event{kind: :resource_updated, uri: "test://resource/one"}}}

    assert :ok = Subscription.close(tools, :cancelled)
    assert :ok = Subscription.close(resource, :cancelled)
    assert %{subscriptions: 0, queued: 0} = Hub.stats(hub)
    assert :ok = Subscription.stop_worker(tools_worker, tools_monitor)
    assert :ok = Subscription.stop_worker(resource_worker, resource_monitor)
  end

  test "bounds each queue and defaults to retaining the newest events" do
    {:ok, hub} = start_supervised({Hub, max_buffer: 2})
    subscription = listen(runtime(hub), "bounded", %{"toolsListChanged" => true})

    assert {:ok, %{buffered: 1, dropped: 0}} = publish_sequence(hub, 1)
    assert {:ok, %{buffered: 1, dropped: 0}} = publish_sequence(hub, 2)
    assert {:ok, %{buffered: 1, dropped: 1}} = publish_sequence(hub, 3)

    assert %{
             subscriptions: 1,
             queued: 2,
             dropped: 1,
             max_buffer: 2,
             overflow: :drop_oldest
           } = Hub.stats(hub)

    {worker, monitor} = Subscription.start_worker(subscription, self())

    :ok = Subscription.continue(worker)
    assert_receive {:mcp_subscription, ^worker, {:ok, first}}
    assert first.metadata == %{"seq" => 2}

    :ok = Subscription.continue(worker)
    assert_receive {:mcp_subscription, ^worker, {:ok, second}}
    assert second.metadata == %{"seq" => 3}

    assert :ok = Hub.complete(hub)
    :ok = Subscription.continue(worker)
    assert_receive {:mcp_subscription, ^worker, :closed}

    assert :ok = Subscription.close(subscription, :complete)
    assert :ok = Subscription.stop_worker(worker, monitor)
  end

  test "can retain the oldest events and report dropped new publications" do
    {:ok, hub} = start_supervised({Hub, max_buffer: 1, overflow: :drop_newest})
    subscription = listen(runtime(hub), "oldest", %{"toolsListChanged" => true})

    assert {:ok, %{buffered: 1, dropped: 0}} = publish_sequence(hub, 1)
    assert {:ok, %{buffered: 0, dropped: 1}} = publish_sequence(hub, 2)

    {worker, monitor} = Subscription.start_worker(subscription, self())
    :ok = Subscription.continue(worker)
    assert_receive {:mcp_subscription, ^worker, {:ok, event}}
    assert event.metadata == %{"seq" => 1}

    assert :ok = Subscription.close(subscription, :cancelled)
    assert :ok = Subscription.stop_worker(worker, monitor)
  end

  test "graceful completion wakes a blocked pull and cancellation releases it" do
    {:ok, hub} = start_supervised(Hub)
    completed = listen(runtime(hub), "complete", %{"toolsListChanged" => true})
    {completed_worker, completed_monitor} = Subscription.start_worker(completed, self())
    :ok = Subscription.continue(completed_worker)

    assert :ok = Hub.complete(hub)
    assert_receive {:mcp_subscription, ^completed_worker, :closed}
    assert %{subscriptions: 1, closing: 1} = Hub.stats(hub)
    assert :ok = Subscription.close(completed, :complete)
    assert %{subscriptions: 0} = Hub.stats(hub)
    assert :ok = Subscription.stop_worker(completed_worker, completed_monitor)

    cancelled = listen(runtime(hub), "cancel", %{"toolsListChanged" => true})
    {cancelled_worker, cancelled_monitor} = Subscription.start_worker(cancelled, self())
    :ok = Subscription.continue(cancelled_worker)
    assert :ok = Subscription.close(cancelled, {:cancelled, "client done"})
    assert_receive {:mcp_subscription, ^cancelled_worker, :closed}
    assert %{subscriptions: 0} = Hub.stats(hub)
    assert :ok = Subscription.stop_worker(cancelled_worker, cancelled_monitor)
  end

  test "validates publications and startup policy" do
    {:ok, hub} = start_supervised(Hub)

    assert {:error, {:invalid_event, message}} =
             Hub.publish(hub, Event.resource_updated("relative/path"))

    assert message =~ "absolute URI"

    assert {:error, {:invalid_event, _message}} = Hub.publish(hub, :not_an_event)

    assert_raise ArgumentError, ~r/max_buffer/, fn -> Hub.start_link(max_buffer: 0) end
    assert_raise ArgumentError, ~r/overflow/, fn -> Hub.start_link(overflow: :unbounded) end
    assert_raise ArgumentError, ~r/unknown/, fn -> Hub.start_link(extra: true) end
  end

  test "core helpers and extension selectors share filter-aware publication" do
    {:ok, hub} = start_supervised(Hub)

    filter = %{
      "promptsListChanged" => true,
      "resourcesListChanged" => true,
      "taskIds" => ["task-one"]
    }

    context = %Snodo.Context{
      protocol_version: "2026-07-28",
      protocol: Snodo.Protocol.V2026_07_28,
      transport: %Snodo.Transport.Context{transport: :direct}
    }

    assert {:ok, ^filter, handle} = Hub.open(filter, context, hub)

    assert {:ok, %{matched: 1}} = Hub.notify_prompts_list_changed(hub)
    assert {:ok, %Event{kind: :prompts_list_changed}} = Hub.next(handle, hub)

    assert {:ok, %{matched: 1}} = Hub.notify_resources_list_changed(hub)
    assert {:ok, %Event{kind: :resources_list_changed}} = Hub.next(handle, hub)

    matching = Event.extension("tasks", %{"taskIds" => ["task-one"]}, :snapshot)
    assert {:ok, %{matched: 1}} = Hub.publish(hub, matching)
    assert {:ok, ^matching} = Hub.next(handle, hub)

    outside_filter = Event.extension("tasks", %{"taskIds" => ["task-two"]}, :snapshot)

    assert {:ok, %{matched: 0, delivered: 0, buffered: 0, dropped: 0}} =
             Hub.publish(hub, outside_filter)

    assert :ok = Hub.close(handle, :cancelled, hub)
  end

  test "instruments open, publication, overflow, completion, and close" do
    {:ok, hub} =
      start_supervised({Hub, max_buffer: 1, instrumentation: {TestInstrumentationSink, self()}})

    subscription = listen(runtime(hub), "instrumented", %{"toolsListChanged" => true})

    assert_receive {:instrumentation, [:snodo, :subscription, :open], %{subscriptions: 1},
                    %{
                      filter_keys: ["toolsListChanged"],
                      request_id: "instrumented",
                      transport: :direct
                    }}

    assert {:ok, %{buffered: 1, dropped: 0}} = Hub.notify_tools_list_changed(hub)

    assert_receive {:instrumentation, [:snodo, :subscription, :publish],
                    %{matched: 1, buffered: 1, dropped: 0, queued: 1},
                    %{event_kind: :tools_list_changed}}

    assert {:ok, %{buffered: 1, dropped: 1}} = Hub.notify_tools_list_changed(hub)

    assert_receive {:instrumentation, [:snodo, :subscription, :publish], %{dropped: 1, queued: 1},
                    _metadata}

    assert_receive {:instrumentation, [:snodo, :subscription, :overflow],
                    %{dropped: 1, queued: 1},
                    %{event_kind: :tools_list_changed, policy: :drop_oldest}}

    assert :ok = Hub.complete(hub)

    assert_receive {:instrumentation, [:snodo, :subscription, :complete],
                    %{subscriptions: 1, queued: 1}, %{}}

    assert :ok = Subscription.close(subscription, {:cancelled, "done"})

    assert_receive {:instrumentation, [:snodo, :subscription, :close], %{subscriptions: 0},
                    %{reason: :cancelled}}
  end

  defp runtime(hub) do
    TestFixtures.runtime(
      capabilities: %{
        "tools" => %{"listChanged" => true},
        "resources" => %{"subscribe" => true}
      },
      subscription_source: Hub.source(hub)
    )
  end

  defp listen(runtime, id, notifications) do
    assert {:stream, subscription} =
             MCPTest.dispatch(runtime,
               id: id,
               protocol: "2026-07-28",
               method: "subscriptions/listen",
               params: %{"notifications" => notifications}
             )

    subscription
  end

  defp publish_sequence(hub, sequence) do
    Hub.notify_tools_list_changed(hub, metadata: %{"seq" => sequence})
  end
end
