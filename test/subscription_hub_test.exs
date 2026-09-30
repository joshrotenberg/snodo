defmodule Snodo.SubscriptionHubTest do
  use ExUnit.Case, async: true

  alias Snodo.Subscription
  alias Snodo.Subscription.Event
  alias Snodo.Subscription.Hub
  alias Snodo.Test, as: MCPTest
  alias SnodoTest.SubscriptionWorker
  alias SnodoTest.TestFixtures
  alias SnodoTest.TestInstrumentationSink
  alias SnodoTest.TestSubscriptionHub
  alias SnodoTest.TestSubscriptionSource

  defmodule RefuseData do
    @behaviour Snodo.Authorization

    @impl true
    def authorize(:invocation, %{uri: "test://static/data"}, _context, _options),
      do: {:error, Snodo.Error.authorization(-32_003, "Not permitted")}

    def authorize(_phase, _component, _context, _options), do: :ok
  end

  # Reports every close to the observer. A pull blocks until the puller is
  # stopped.
  defmodule RecordingSource do
    @behaviour Snodo.Subscription.Source

    @impl true
    def open(filter, _context, observer), do: {:ok, filter, observer}

    @impl true
    def next(_observer, _options) do
      receive do
        :recording_source_never_sent -> :closed
      end
    end

    @impl true
    def close(observer, reason, _options), do: send(observer, {:source_closed, reason})
  end

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

  test "resource update index tracks matching listeners through close and completion" do
    {:ok, hub} = start_supervised(Hub)

    context = %Snodo.Context{
      request_id: "uri-index",
      protocol_version: "2026-07-28",
      protocol: Snodo.Protocol.V2026_07_28,
      transport: %Snodo.Transport.Context{transport: :direct}
    }

    unrelated =
      for group <- 1..30 do
        uris = for number <- 1..200, do: "test://other/#{group}/#{number}"
        {:ok, _, handle} = Hub.open(%{"resourceSubscriptions" => uris}, context, hub)
        handle
      end

    target = "test://resource/target"
    filter = %{"resourceSubscriptions" => [target]}
    {:ok, _, first} = Hub.open(filter, context, hub)
    {:ok, _, second} = Hub.open(filter, context, hub)

    assert Map.fetch!(:sys.get_state(hub).uri_index, target) ==
             MapSet.new([elem(first, 1), elem(second, 1)])

    assert {:ok, %{matched: 2, buffered: 2}} = Hub.notify_resource_updated(hub, target)
    assert %{queued: 2} = Hub.stats(hub)
    assert {:ok, %Event{uri: ^target}} = Hub.next(second, hub)
    assert %{queued: 1} = Hub.stats(hub)
    assert {:ok, %{matched: 0, buffered: 0}} = Hub.notify_resource_updated(hub, "test://absent")

    assert :ok = Hub.close(first, :cancelled, hub)
    assert %{queued: 0} = Hub.stats(hub)
    assert Map.fetch!(:sys.get_state(hub).uri_index, target) == MapSet.new([elem(second, 1)])
    assert {:ok, %{matched: 1, buffered: 1}} = Hub.notify_resource_updated(hub, target)
    assert {:ok, %Event{uri: ^target}} = Hub.next(second, hub)

    assert :ok = Hub.complete(hub)
    assert :sys.get_state(hub).uri_index == %{}
    assert {:ok, %{matched: 0, buffered: 0}} = Hub.notify_resource_updated(hub, target)

    assert :ok = Hub.close(second, :complete, hub)
    Enum.each(unrelated, &Hub.close(&1, :cancelled, hub))
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
    assert %{queued: 1, dropped: 1} = Hub.stats(hub)

    {worker, monitor} = Subscription.start_worker(subscription, self())
    :ok = Subscription.continue(worker)
    assert_receive {:mcp_subscription, ^worker, {:ok, event}}
    assert event.metadata == %{"seq" => 1}
    assert %{queued: 0} = Hub.stats(hub)

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

  test "a worker closes its source and exits when its owner exits" do
    subscription = listen(recording_runtime(), "orphaned", %{"toolsListChanged" => true})
    test = self()

    owner =
      spawn(fn ->
        {worker, _monitor} = Subscription.start_worker(subscription, self())
        :ok = Subscription.continue(worker)
        send(test, {:worker, worker})
        Process.sleep(:infinity)
      end)

    assert_receive {:worker, worker}, 1_000
    puller = SubscriptionWorker.puller(worker)

    [{^worker, worker_monitor}, {^puller, puller_monitor}] =
      SubscriptionWorker.monitor_confirmed([worker, puller])

    # With the worker's monitor in place, it sees the owner's exit reason.
    :ok = SubscriptionWorker.await_monitor(owner, worker)
    Process.exit(owner, :kill)

    assert_receive {:source_closed, {:disconnected, {:owner_down, :killed}}}, 1_000
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :shutdown}, 1_000
    assert_receive {:DOWN, ^puller_monitor, :process, ^puller, :shutdown}, 1_000
    refute_received {:source_closed, _reason}
  end

  test "a stopped worker leaves closing the source to its owner" do
    subscription = listen(recording_runtime(), "stopped", %{"toolsListChanged" => true})
    test = self()

    owner =
      spawn(fn ->
        {worker, monitor} = Subscription.start_worker(subscription, self())
        :ok = Subscription.continue(worker)
        send(test, {:worker, worker})

        receive do
          :stop ->
            :ok = Subscription.close(subscription, :complete)
            :ok = Subscription.stop_worker(worker, monitor)
        end
      end)

    assert_receive {:worker, worker}, 1_000
    puller = SubscriptionWorker.puller(worker)
    monitors = SubscriptionWorker.monitor_confirmed([owner, worker, puller])
    send(owner, :stop)

    assert_receive {:source_closed, :complete}, 1_000

    for {pid, monitor} <- monitors do
      assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}, 1_000
    end

    # A close by the worker would reach this process before the worker's DOWN.
    refute_received {:source_closed, _reason}
  end

  # The owner stops a worker and closes its handle from different processes, so
  # the puller's next/2 can reach a source after close/3. This drives that order
  # directly.
  test "a pull after the owner closed the handle answers :closed" do
    {:ok, hub} = start_supervised(Hub)
    {:ok, test_hub} = start_supervised(TestSubscriptionHub)

    runtimes = [
      runtime(hub),
      TestFixtures.runtime(
        capabilities: %{"tools" => %{"listChanged" => true}},
        subscription_source: {TestSubscriptionSource, test_hub}
      )
    ]

    for runtime <- runtimes do
      subscription = listen(runtime, "closed-first", %{"toolsListChanged" => true})
      assert :ok = Subscription.close(subscription, :cancelled)

      {worker, monitor} = Subscription.start_worker(subscription, self())
      :ok = Subscription.continue(worker)
      assert_receive {:mcp_subscription, ^worker, :closed}, 1_000
      assert :ok = Subscription.stop_worker(worker, monitor)
    end

    assert Process.alive?(hub)
    assert Process.alive?(test_hub)
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

  test "resource subscriptions leave out resources the caller may not read" do
    {:ok, hub} = start_supervised(Hub)

    runtime =
      TestFixtures.runtime(
        resources: [SnodoTest.TestResources.StaticText, SnodoTest.TestResources.StaticJSON],
        capabilities: %{"resources" => %{"subscribe" => true}},
        subscription_source: Hub.source(hub),
        authorization: RefuseData
      )

    requested = ["test://static/readme", "test://static/data", "test://unregistered/one"]
    subscription = listen(runtime, "filtered", %{"resourceSubscriptions" => requested})

    assert subscription.accepted_filter["resourceSubscriptions"] ==
             ["test://static/readme", "test://unregistered/one"]

    assert :ok = Subscription.close(subscription, :cancelled)
  end

  test "a listen request may name up to 1,000 resource URIs" do
    {:ok, hub} = start_supervised(Hub)
    runtime = runtime(hub)
    uris = for n <- 1..1_000, do: "test://resource/#{n}"

    subscription = listen(runtime, "at-limit", %{"resourceSubscriptions" => uris})
    assert :ok = Subscription.close(subscription, :cancelled)

    assert {:ok, %{"error" => %{"code" => -32_602} = error}} =
             MCPTest.dispatch(runtime,
               id: "over-limit",
               protocol: "2026-07-28",
               method: "subscriptions/listen",
               params: %{
                 "notifications" => %{"resourceSubscriptions" => ["test://extra" | uris]}
               }
             )

    assert inspect(error) =~ "at most 1000"
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

  defp recording_runtime do
    TestFixtures.runtime(
      capabilities: %{"tools" => %{"listChanged" => true}},
      subscription_source: {RecordingSource, self()}
    )
  end

  defp publish_sequence(hub, sequence) do
    Hub.notify_tools_list_changed(hub, metadata: %{"seq" => sequence})
  end
end
