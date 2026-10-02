defmodule Snodo.ClientCacheTest do
  use ExUnit.Case, async: false

  alias Snodo.Client
  alias Snodo.Client.Cache
  alias Snodo.Client.Subscription
  alias Snodo.Subscription.Event
  alias SnodoTest.TestFixtures
  alias SnodoTest.TestInstrumentationSink
  alias SnodoTest.TestSubscriptionHub
  alias SnodoTest.TestSubscriptionSource

  defmodule CachedResource do
    use Snodo.Resource, uri: "test://cached/item", name: "cached_item"

    @impl true
    def read(%{"uri" => uri}, _context) do
      {:ok,
       Snodo.Result.resource_read(Snodo.Resource.text(uri, "cached"),
         metadata: %{ttl_ms: 5_000, cache_scope: "private"}
       )}
    end
  end

  defp runtime(opts) do
    TestFixtures.runtime([instrumentation: {TestInstrumentationSink, self()}] ++ opts)
  end

  defp client(runtime, opts \\ []) do
    {:ok, client} = Client.direct(runtime, [cache: true] ++ opts)
    client
  end

  defp assert_dispatched(method) do
    assert_receive {:instrumentation, [:snodo, :server, :dispatch, :start], _measurements,
                    %{method: ^method}},
                   1_000
  end

  defp refute_dispatched(method) do
    refute_received {:instrumentation, [:snodo, :server, :dispatch, :start], _measurements,
                     %{method: ^method}}
  end

  test "public discovery results are shared, expire, and can be bypassed" do
    runtime = runtime(discovery_cache: [ttl_ms: 100, scope: "public"])
    first = client(runtime, auth: "first")
    second = client(runtime, auth: "second")

    assert {:ok, result} = Client.discover(first)
    assert result["cacheScope"] == "public"
    assert_dispatched("server/discover")

    assert {:ok, ^result} = Client.discover(second)
    refute_dispatched("server/discover")

    assert {:ok, ^result} = Client.discover(second, bypass_cache: true)
    assert_dispatched("server/discover")

    Process.send_after(self(), :cache_expired, 120)
    assert_receive :cache_expired, 1_000
    assert {:ok, ^result} = Client.discover(first)
    assert_dispatched("server/discover")
  end

  test "private discovery results are partitioned by direct-client credentials" do
    runtime = runtime(discovery_cache: [ttl_ms: 5_000, scope: "private"])
    first = client(runtime, auth: "first")
    second = client(runtime, auth: "second")

    assert {:ok, _result} = Client.discover(first)
    assert_dispatched("server/discover")
    assert {:ok, _result} = Client.discover(first)
    refute_dispatched("server/discover")

    assert {:ok, _result} = Client.discover(second)
    assert_dispatched("server/discover")
    assert {:ok, _result} = Client.discover(second)
    refute_dispatched("server/discover")
  end

  test "a result without a positive TTL is not cached" do
    client = client(runtime([]))

    assert {:ok, %{"ttlMs" => 0}} = Client.discover(client)
    assert_dispatched("server/discover")
    assert {:ok, %{"ttlMs" => 0}} = Client.discover(client)
    assert_dispatched("server/discover")
  end

  test "list pages and resource reads use hints, while an uncached client sends every request" do
    runtime =
      runtime(
        tools_cache: [ttl_ms: 5_000, scope: "public"],
        resources: [CachedResource]
      )

    cached = client(runtime)
    {:ok, uncached} = Client.direct(runtime)

    assert {:ok, _page} = Client.list_page(cached, :tools)
    assert_dispatched("tools/list")
    assert {:ok, _page} = Client.list_page(cached, :tools)
    refute_dispatched("tools/list")
    assert {:ok, _page} = Client.list_page(cached, :tools, nil, bypass_cache: true)
    assert_dispatched("tools/list")

    assert {:ok, _result} = Client.read_resource(cached, "test://cached/item")
    assert_dispatched("resources/read")
    assert {:ok, _result} = Client.read_resource(cached, "test://cached/item")
    refute_dispatched("resources/read")

    assert {:ok, _page} = Client.list_page(uncached, :tools)
    assert_dispatched("tools/list")
    assert {:ok, _page} = Client.list_page(uncached, :tools)
    assert_dispatched("tools/list")
  end

  test "list changes and resource updates invalidate cached responses while listening" do
    {:ok, hub} = start_supervised({TestSubscriptionHub, owner: self()})

    runtime =
      runtime(
        tools_cache: [ttl_ms: 5_000, scope: "public"],
        resources: [CachedResource],
        capabilities: %{
          "tools" => %{"listChanged" => true},
          "resources" => %{"subscribe" => true}
        },
        subscription_source: {TestSubscriptionSource, hub}
      )

    client = client(runtime)
    assert {:ok, _tools} = Client.list_tools(client)
    assert_dispatched("tools/list")
    assert {:ok, _result} = Client.read_resource(client, "test://cached/item")
    assert_dispatched("resources/read")

    assert {:ok, subscription} =
             Client.listen(client, %{
               "toolsListChanged" => true,
               "resourceSubscriptions" => ["test://cached/item"]
             })

    assert_receive {:subscription_opened, id, _accepted}, 1_000
    assert :ok = TestSubscriptionHub.emit(hub, id, Event.tools_list_changed())

    assert {:notification, "notifications/tools/list_changed", _params} =
             Subscription.next(subscription, 1_000)

    assert {:ok, _tools} = Client.list_tools(client)
    assert_dispatched("tools/list")
    assert {:ok, _result} = Client.read_resource(client, "test://cached/item")
    refute_dispatched("resources/read")

    assert :ok = TestSubscriptionHub.emit(hub, id, Event.resource_updated("test://cached/item"))

    assert {:notification, "notifications/resources/updated", _params} =
             Subscription.next(subscription, 1_000)

    assert {:ok, _result} = Client.read_resource(client, "test://cached/item")
    assert_dispatched("resources/read")
    assert :ok = Subscription.close(subscription)
  end

  test "the shared cache evicts old entries at its entry limit" do
    namespace = {:test, make_ref()}
    result = %{"ttlMs" => 5_000, "cacheScope" => "public", "resultType" => "complete"}

    for n <- 1..257 do
      base = {namespace, "2026-07-28", nil, %{}, %{}, "server/discover", %{"n" => n}}
      {:miss, generation} = Cache.lookup_public(base)
      assert :ok = Cache.put(base, :anonymous, generation, result)
    end

    first = {namespace, "2026-07-28", nil, %{}, %{}, "server/discover", %{"n" => 1}}
    last = {namespace, "2026-07-28", nil, %{}, %{}, "server/discover", %{"n" => 257}}
    assert {:miss, _generation} = Cache.lookup_public(first)
    assert {:hit, ^result} = Cache.lookup_public(last)
    assert map_size(:sys.get_state(Cache).entries) <= 256
  end

  test "a notification prevents an in-flight response from repopulating invalidated data" do
    namespace = {:test, make_ref()}
    base = {namespace, "2026-07-28", nil, %{}, %{}, "tools/list", %{}}
    result = %{"ttlMs" => 5_000, "cacheScope" => "private", "tools" => []}

    assert {:miss, generation} = Cache.lookup_private(base, :credential)
    assert :ok = Cache.invalidate(namespace, "notifications/tools/list_changed", %{})
    assert :ok = Cache.put(base, :credential, generation, result)
    assert {:miss, _generation} = Cache.lookup_private(base, :credential)
  end

  test "invalid cache options are rejected" do
    runtime = runtime([])

    assert_raise ArgumentError, ~r/:cache must be a boolean/, fn ->
      Client.direct(runtime, cache: :enabled)
    end

    client = client(runtime)

    assert_raise ArgumentError, ~r/:bypass_cache must be a boolean/, fn ->
      Client.discover(client, bypass_cache: :yes)
    end
  end
end
