defmodule Snodo.Proxy.ManagerTest do
  use ExUnit.Case, async: true

  alias Snodo.Client
  alias Snodo.Client.Subscription
  alias Snodo.Proxy
  alias Snodo.Proxy.Manager
  alias Snodo.Proxy.Supervisor, as: ProxySupervisor

  defmodule Tools do
    use Snodo.Server, name: "tools", version: "1.0.0"

    tool "one" do
      @impl true
      def call(_arguments, _context), do: {:ok, "one"}
    end

    tool "two" do
      @impl true
      def call(_arguments, _context), do: {:ok, "two"}
    end
  end

  defmodule CatalogPolicy do
    @behaviour Snodo.Authorization

    @impl true
    def authorize(:discovery, %{name: "two"}, _context, mode) do
      if Agent.get(mode, & &1) == :expanded do
        :ok
      else
        {:error, Snodo.Error.authorization(-32_003, "Tool is hidden")}
      end
    end

    def authorize(_phase, _component, _context, _mode), do: :ok
  end

  defp direct, do: {:direct, Tools.runtime()}

  test "add_backend/2 refuses invalid, duplicate, and over-limit backends" do
    proxy = start_supervised!({Proxy, max_backends: 1, backends: [[id: "a", target: direct()]]})

    assert {:error, :invalid_backend} = Proxy.add_backend(proxy, id: "1bad", target: direct())
    assert {:error, :invalid_backend} = Proxy.add_backend(proxy, target: direct())

    assert {:error, {:duplicate_backend, "a"}} =
             Proxy.add_backend(proxy, id: "a", target: direct())

    assert {:error, {:backend_limit, 1}} = Proxy.add_backend(proxy, id: "b", target: direct())
    assert %{"a" => %{status: :up}} = Proxy.health(proxy)
  end

  test "a backend whose catalog exceeds the item limit is not added" do
    proxy = start_supervised!({Proxy, max_catalog_items: 1, backends: []})

    assert {:error, {:catalog_limit, 1}} = Proxy.add_backend(proxy, id: "a", target: direct())
    assert Proxy.health(proxy) == %{}
  end

  test "an oversized catalog update keeps the backend running with its last accepted catalog" do
    mode = start_supervised!({Agent, fn -> :initial end})
    runtime = Tools.runtime(authorization: {CatalogPolicy, mode})

    proxy =
      start_supervised!(
        {Proxy, max_catalog_items: 1, backends: [[id: "a", target: {:direct, runtime}]]}
      )

    accepted = Manager.catalog(proxy)
    backend = accepted.tools["a.one"].backend_pid
    :ok = Agent.update(mode, fn _ -> :expanded end)

    assert {:error, {:catalog_limit, 1}} = Proxy.refresh_backend(proxy, "a")
    assert %{status: :degraded, error: {:catalog_limit, 1}} = Proxy.health(proxy)["a"]
    assert Manager.catalog(proxy) == accepted

    # Exercise the same rejection when the snapshot arrives as a readiness report.
    snapshot =
      backend
      |> :sys.get_state()
      |> Map.take([:id, :prefix, :client, :catalog])
      |> Map.merge(%{pid: backend, subscribed_uris: MapSet.new()})

    manager = ProxySupervisor.child(proxy, Manager)
    send(manager, {:backend_ready, "a", backend, snapshot})

    assert %{status: :degraded, error: {:catalog_limit, 1}, reconnect_attempt: 0} =
             Proxy.health(proxy)["a"]

    assert Process.alive?(backend)
    assert Manager.catalog(proxy) == accepted
  end

  test "a backend that cannot connect is not added" do
    proxy = start_supervised!({Proxy, backends: []})
    {:ok, closed} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(closed)
    :ok = :gen_tcp.close(closed)

    assert {:error, _reason} =
             Proxy.add_backend(proxy, id: "gone", target: {:http, "http://127.0.0.1:#{port}/mcp"})

    assert Proxy.health(proxy) == %{}
  end

  test "remove_backend/2 and refresh_backend/2 report unknown backends" do
    proxy = start_supervised!({Proxy, backends: [[id: "a", target: direct()]]})

    assert {:error, :not_found} = Proxy.remove_backend(proxy, "missing")
    assert {:error, :not_found} = Proxy.refresh_backend(proxy, "missing")
    assert :ok = Proxy.refresh_backend(proxy, "a")
    assert :ok = Proxy.remove_backend(proxy, "a")
    assert {:error, :not_found} = Proxy.refresh_backend(proxy, "a")
  end

  test "reconnect delays double until they hit the cap" do
    opts = %{initial_ms: 1_000, max_ms: 30_000}

    delays =
      Enum.scan(1..8, nil, fn _attempt, previous ->
        Manager.reconnect_delay(previous, opts)
      end)

    assert delays == [1_000, 2_000, 4_000, 8_000, 16_000, 30_000, 30_000, 30_000]
  end

  test "reconnect history resets only after stable uptime" do
    history = %{ready_since: -100, reconnect_attempt: 3, reconnect_delay_ms: 4_000}

    assert Manager.reconnect_history(history, -41, 60) == {3, 4_000}
    assert Manager.reconnect_history(history, -40, 60) == {0, nil}
    assert Manager.reconnect_history(%{history | ready_since: nil}, 100, 60) == {3, 4_000}
  end

  test "a crashed direct backend reconnects and restores its catalog" do
    proxy =
      start_supervised!(
        {Proxy,
         reconnect_initial_ms: 5, reconnect_max_ms: 20, backends: [[id: "a", target: direct()]]}
      )

    {:ok, client} = Client.direct(Proxy.runtime(proxy))
    assert {:ok, subscription} = Client.listen(client, %{"toolsListChanged" => true})
    backend = Manager.catalog(proxy).tools["a.one"].backend_pid
    Process.exit(backend, :kill)

    for _change <- 1..2 do
      assert {:notification, "notifications/tools/list_changed", _params} =
               Subscription.next(subscription, 1_000)
    end

    assert %{status: :up, error: nil, reconnect_attempt: 1, reconnect_delay_ms: 5} =
             Proxy.health(proxy)["a"]

    assert Manager.catalog(proxy).tools["a.one"].backend_pid != backend
  end

  test "start_link/1 rejects invalid limits" do
    for opts <- [
          [max_backends: 0],
          [max_catalog_items: -1],
          [health_interval_ms: :never],
          [reconnect_initial_ms: 0],
          [reconnect_max_ms: 999],
          [reconnect_max_ms: 4_294_967_296],
          [reconnect_reset_ms: :never]
        ] do
      assert {:error,
              {{:shutdown, {:failed_to_start_child, _manager, {%ArgumentError{}, _stack}}},
               _child}} = start_supervised({Proxy, [backends: []] ++ opts})
    end
  end
end
