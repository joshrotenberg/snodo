defmodule Snodo.ClientListenTest do
  use ExUnit.Case, async: true

  alias Snodo.Client
  alias Snodo.Client.Subscription
  alias Snodo.Client.Subscription.Buffer
  alias Snodo.Error
  alias Snodo.Subscription.Event
  alias SnodoTest.TestExtensions.Watch
  alias SnodoTest.TestFixtures
  alias SnodoTest.TestSubscriptionHub
  alias SnodoTest.TestSubscriptionSource

  @subscription_id_key "io.modelcontextprotocol/subscriptionId"
  @cancelled {:cancelled, "Closed by the client"}

  defmodule NoListenTransport do
    @moduledoc false
    @behaviour Snodo.Client.Transport

    @impl true
    def connect(state, _opts), do: {:ok, state}

    @impl true
    def request(_state, message, _opts),
      do: {:ok, %{"jsonrpc" => "2.0", "id" => message["id"], "result" => %{}}}

    @impl true
    def close(_state), do: :ok
  end

  defp start_hub(context) do
    {:ok, hub} = start_supervised({TestSubscriptionHub, owner: self()})
    Map.put(context, :hub, hub)
  end

  defp client(hub, opts \\ [], client_opts \\ []) do
    capabilities =
      Keyword.get(opts, :capabilities, %{
        "tools" => %{"listChanged" => true},
        "resources" => %{"subscribe" => true}
      })

    runtime =
      TestFixtures.runtime(
        capabilities: capabilities,
        subscription_source: {TestSubscriptionSource, hub},
        extensions: Keyword.get(opts, :extensions, [])
      )

    {:ok, client} = Client.direct(runtime, client_opts)
    client
  end

  defp listen!(client, notifications, opts \\ []) do
    {:ok, subscription} = Client.listen(client, notifications, opts)
    subscription
  end

  defp tools_changed(sequence), do: Event.tools_list_changed(metadata: %{"seq" => sequence})

  # The hub reports each pull. The worker pulls the next event only after the
  # stream process has taken the previous one, so `count` pulls mean that
  # `count - 1` events have reached the client's buffer.
  defp await_pulls(id, count) do
    for _pull <- 1..count, do: assert_receive({:subscription_next, ^id}, 1_000)
  end

  setup :start_hub

  describe "listen/3 over the direct client" do
    test "returns the handle with the filter the server accepted", %{hub: hub} do
      requested = %{
        "toolsListChanged" => true,
        "promptsListChanged" => true,
        "resourceSubscriptions" => ["test://resource/one"]
      }

      assert {:ok, %Subscription{} = subscription} = Client.listen(client(hub), requested)
      assert subscription.accepted == Map.delete(requested, "promptsListChanged")
      assert is_integer(subscription.id) and is_reference(subscription.ref)
      assert subscription.owner == self() and is_pid(subscription.pid)

      id = subscription.id
      assert_receive {:subscription_opened, ^id, accepted}, 1_000
      assert accepted == subscription.accepted
    end

    test "delivers resource updates and list changes as messages while there is demand",
         %{hub: hub} do
      subscription =
        listen!(client(hub), %{
          "toolsListChanged" => true,
          "resourceSubscriptions" => ["test://resource/one"]
        })

      %{id: id, ref: ref} = subscription
      :ok = Subscription.demand(subscription, 2)

      :ok = TestSubscriptionHub.emit(hub, id, Event.resource_updated("test://resource/one"))
      :ok = TestSubscriptionHub.emit(hub, id, tools_changed(1))
      :ok = TestSubscriptionHub.emit(hub, id, tools_changed(2))

      assert_receive {:snodo_subscription, ^ref,
                      {:notification, "notifications/resources/updated", updated}},
                     1_000

      assert updated["uri"] == "test://resource/one"
      assert updated["_meta"][@subscription_id_key] == id

      assert_receive {:snodo_subscription, ^ref,
                      {:notification, "notifications/tools/list_changed", first}},
                     1_000

      assert first["_meta"]["seq"] == 1

      # The third event waits for demand.
      refute_receive {:snodo_subscription, ^ref, _payload}, 100
      :ok = Subscription.demand(subscription, 1)

      assert_receive {:snodo_subscription, ^ref,
                      {:notification, "notifications/tools/list_changed", second}},
                     1_000

      assert second["_meta"]["seq"] == 2
    end

    test "next/2 returns one payload and stream/1 runs to the terminal result", %{hub: hub} do
      subscription = listen!(client(hub), %{"toolsListChanged" => true})
      id = subscription.id

      :ok = TestSubscriptionHub.emit(hub, id, tools_changed(1))

      assert {:notification, "notifications/tools/list_changed", %{"_meta" => %{"seq" => 1}}} =
               Subscription.next(subscription, 1_000)

      :ok = TestSubscriptionHub.emit(hub, id, tools_changed(2))
      :ok = TestSubscriptionHub.emit(hub, id, tools_changed(3))
      :ok = TestSubscriptionHub.complete(hub, id)

      assert [
               {:notification, "notifications/tools/list_changed", %{"_meta" => %{"seq" => 2}}},
               {:notification, "notifications/tools/list_changed", %{"_meta" => %{"seq" => 3}}},
               {:closed, :complete}
             ] = subscription |> Subscription.stream() |> Enum.to_list()

      assert_receive {:subscription_closed, ^id, :complete}, 1_000
    end

    test "extension events arrive with the extension's method", %{hub: hub} do
      client =
        client(
          hub,
          [
            capabilities: %{
              "tools" => %{"listChanged" => true},
              "extensions" => %{"com.example/watch" => %{}}
            },
            extensions: [Watch]
          ],
          client_capabilities: %{"extensions" => %{"com.example/watch" => %{}}}
        )

      subscription = listen!(client, %{"toolsListChanged" => true, "watchIds" => ["w1"]})
      assert subscription.accepted == %{"toolsListChanged" => true, "watchIds" => ["w1"]}
      %{id: id, ref: ref} = subscription
      :ok = Subscription.demand(subscription, 5)

      outside = Event.extension("com.example/watch", %{"watchIds" => ["w2"]}, "ignored")
      :ok = TestSubscriptionHub.emit(hub, id, outside)

      selected =
        Event.extension("com.example/watch", %{"watchIds" => ["w1"]}, %{"state" => "done"})

      :ok = TestSubscriptionHub.emit(hub, id, selected)

      assert_receive {:snodo_subscription, ^ref,
                      {:notification, "notifications/com.example/watch", params}},
                     1_000

      assert params["watch"] == %{"state" => "done"}
      assert params["_meta"][@subscription_id_key] == id
      refute_received {:snodo_subscription, ^ref, _other}
    end

    test "a full buffer drops the oldest event by default and reports the count", %{hub: hub} do
      subscription = listen!(client(hub), %{"toolsListChanged" => true}, max_buffer: 2)
      %{id: id, ref: ref} = subscription

      for sequence <- 1..3, do: :ok = TestSubscriptionHub.emit(hub, id, tools_changed(sequence))
      await_pulls(id, 4)

      :ok = Subscription.demand(subscription, 10)
      assert_receive {:snodo_subscription, ^ref, {:dropped, 1}}, 1_000
      assert_receive {:snodo_subscription, ^ref, {:notification, _method, second}}, 1_000
      assert second["_meta"]["seq"] == 2
      assert_receive {:snodo_subscription, ^ref, {:notification, _method, third}}, 1_000
      assert third["_meta"]["seq"] == 3
      refute_received {:snodo_subscription, ^ref, _other}
    end

    test "drop_newest keeps the oldest events", %{hub: hub} do
      subscription =
        listen!(client(hub), %{"toolsListChanged" => true},
          max_buffer: 1,
          overflow: :drop_newest
        )

      %{id: id, ref: ref} = subscription

      for sequence <- 1..3, do: :ok = TestSubscriptionHub.emit(hub, id, tools_changed(sequence))
      await_pulls(id, 4)

      assert {:dropped, 2} = Subscription.next(subscription, 1_000)

      assert {:notification, _method, %{"_meta" => %{"seq" => 1}}} =
               Subscription.next(subscription, 1_000)

      refute_received {:snodo_subscription, ^ref, _other}
    end

    test "close/1 cancels the stream, closes the source, and ends the process", %{hub: hub} do
      subscription = listen!(client(hub), %{"toolsListChanged" => true})
      %{id: id, pid: pid} = subscription
      monitor = Process.monitor(pid)

      assert :ok = Subscription.close(subscription)
      assert_receive {:subscription_closed, ^id, @cancelled}, 1_000
      assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 1_000
      assert TestSubscriptionHub.count(hub) == 0

      assert :ok = Subscription.close(subscription)
      refute_received {:snodo_subscription, _ref, _payload}
    end

    test "the owner's exit closes the source and ends the process", %{hub: hub} do
      client = client(hub)
      test = self()

      owner =
        spawn(fn ->
          send(test, {:listening, listen!(client, %{"toolsListChanged" => true})})
          Process.sleep(:infinity)
        end)

      assert_receive {:listening, %Subscription{id: id, pid: pid}}, 1_000
      monitor = Process.monitor(pid)
      Process.exit(owner, :kill)

      assert_receive {:subscription_closed, ^id, {:disconnected, {:owner_down, :killed}}}, 1_000
      assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 1_000
      assert TestSubscriptionHub.count(hub) == 0
    end

    test "the server's terminal result follows the queued events", %{hub: hub} do
      subscription = listen!(client(hub), %{"toolsListChanged" => true})
      %{id: id, ref: ref, pid: pid} = subscription
      monitor = Process.monitor(pid)

      :ok = TestSubscriptionHub.emit(hub, id, tools_changed(1))
      :ok = TestSubscriptionHub.emit(hub, id, tools_changed(2))
      :ok = TestSubscriptionHub.complete(hub, id)
      assert_receive {:subscription_closed, ^id, :complete}, 1_000

      assert {:notification, _method, %{"_meta" => %{"seq" => 1}}} =
               Subscription.next(subscription, 1_000)

      refute_receive {:snodo_subscription, ^ref, _payload}, 50
      assert Process.alive?(pid)

      assert {:notification, _method, %{"_meta" => %{"seq" => 2}}} =
               Subscription.next(subscription, 1_000)

      assert_receive {:snodo_subscription, ^ref, {:closed, :complete}}, 1_000
      assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 1_000
    end

    test "a source failure ends the stream with the server's error", %{hub: hub} do
      subscription = listen!(client(hub), %{"toolsListChanged" => true})
      id = subscription.id

      :ok = TestSubscriptionHub.fail(hub, id, :boom)

      assert {:closed, {:error, %Error{code: -32_603, kind: :execution, message: message}}} =
               Subscription.next(subscription, 1_000)

      assert message =~ "Subscription source failed"
      assert_receive {:subscription_closed, ^id, {:error, :boom}}, 1_000
    end

    test "an error response is returned instead of a handle", %{hub: hub} do
      {:ok, unconfigured} = Client.direct(TestFixtures.runtime())

      assert {:error, %Error{code: -32_601, kind: :protocol}} =
               Client.listen(unconfigured, %{"toolsListChanged" => true})

      assert {:error, %Error{code: -32_602, kind: :protocol}} =
               Client.listen(client(hub), %{"toolsListChanged" => "yes"})

      refute_received {:subscription_opened, _id, _filter}
    end

    test "next/2 times out without losing its demand and belongs to the owner", %{hub: hub} do
      subscription = listen!(client(hub), %{"toolsListChanged" => true})
      %{id: id, ref: ref} = subscription

      assert {:error, :timeout} = Subscription.next(subscription, 10)
      :ok = TestSubscriptionHub.emit(hub, id, tools_changed(1))
      assert_receive {:snodo_subscription, ^ref, {:notification, _method, _params}}, 1_000

      task = Task.async(fn -> catch_error(Subscription.next(subscription, 10)) end)
      assert %ArgumentError{message: message} = Task.await(task, 1_000)
      assert message =~ "must be called by the owner"
    end

    test "validates its options and the transport", %{hub: hub} do
      client = client(hub)
      filter = %{"toolsListChanged" => true}

      assert_raise ArgumentError, ~r/:max_buffer must be a positive integer/, fn ->
        Client.listen(client, filter, max_buffer: 0)
      end

      assert_raise ArgumentError, ~r/:overflow must be one of/, fn ->
        Client.listen(client, filter, overflow: :block)
      end

      {:ok, plain} = Client.connect({NoListenTransport, nil}, protocol: "2026-07-28")

      assert_raise ArgumentError, ~r/does not implement listen\/3/, fn ->
        Client.listen(plain, filter)
      end

      assert_raise ArgumentError, ~r/open it with Snodo.Client.listen\/3/, fn ->
        Client.request(client, "subscriptions/listen", %{"notifications" => filter})
      end

      refute_received {:subscription_opened, _id, _filter}
    end
  end

  describe "Buffer" do
    setup do
      %{buffer: Buffer.new(self(), make_ref(), max_buffer: 2, overflow: :drop_oldest)}
    end

    test "abort/2 discards queued events and ends the stream at once", %{buffer: buffer} do
      ref = buffer.ref
      buffer = Buffer.push(buffer, {:notification, "m", %{"n" => 1}})
      refute_received {:snodo_subscription, ^ref, _payload}

      buffer = Buffer.abort(buffer, {:error, :gone})
      assert Buffer.done?(buffer)
      assert_received {:snodo_subscription, ^ref, {:closed, {:error, :gone}}}

      buffer = buffer |> Buffer.demand(1) |> Buffer.close(:complete)
      assert Buffer.done?(Buffer.push(buffer, {:notification, "m", %{"n" => 2}}))
      refute_received {:snodo_subscription, ^ref, _payload}
    end

    test "close/2 waits for the queued events and delivers the drop count once",
         %{buffer: buffer} do
      ref = buffer.ref

      buffer =
        Enum.reduce(1..3, buffer, fn n, buffer ->
          Buffer.push(buffer, {:notification, "m", %{"n" => n}})
        end)

      buffer = Buffer.close(buffer, :complete)
      refute Buffer.done?(buffer)
      refute_received {:snodo_subscription, ^ref, _payload}

      buffer = Buffer.demand(buffer, 1)
      assert_received {:snodo_subscription, ^ref, {:dropped, 1}}
      assert_received {:snodo_subscription, ^ref, {:notification, "m", %{"n" => 2}}}
      refute_received {:snodo_subscription, ^ref, _payload}

      buffer = Buffer.demand(buffer, 1)
      assert_received {:snodo_subscription, ^ref, {:notification, "m", %{"n" => 3}}}
      assert_received {:snodo_subscription, ^ref, {:closed, :complete}}
      assert Buffer.done?(buffer)
    end
  end
end
