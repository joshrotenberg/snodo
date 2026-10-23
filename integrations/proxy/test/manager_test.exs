defmodule Snodo.Proxy.ManagerTest do
  use ExUnit.Case, async: true

  alias Snodo.Proxy

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

  test "start_link/1 rejects invalid limits" do
    for opts <- [[max_backends: 0], [max_catalog_items: -1], [health_interval_ms: :never]] do
      assert {:error,
              {{:shutdown, {:failed_to_start_child, _manager, {%ArgumentError{}, _stack}}},
               _child}} = start_supervised({Proxy, [backends: []] ++ opts})
    end
  end
end
