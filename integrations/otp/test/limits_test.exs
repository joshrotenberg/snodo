defmodule Snodo.OTP.LimitsTest do
  use ExUnit.Case, async: false

  alias Snodo.OTP.Proxy
  alias Snodo.Transport.StreamableHTTP.Server, as: HTTPServer
  alias SnodoTest.OTP.Counter
  alias SnodoTest.OTP.CounterContract
  alias SnodoTest.OTP.CounterServer

  setup do
    start_supervised!(Counter)
    server = start_supervised!({HTTPServer, runtime: CounterServer.runtime(), port: 0})
    %{url: HTTPServer.url(server)}
  end

  test "a call beyond :max_queue is answered :queue_full and the rest still run", %{url: url} do
    proxy = start_supervised!({Proxy, url: url, contract: CounterContract, max_queue: 1})

    # Sent from one process, so they arrive in this order: the first goes out,
    # the second waits, the third finds the queue full.
    first = :gen_server.send_request(proxy, {:slow, 200})
    second = :gen_server.send_request(proxy, {:add, 1})
    assert GenServer.call(proxy, :get) == {:error, :queue_full}
    :ok = GenServer.cast(proxy, {:add, 5})

    assert {:reply, _} = :gen_server.wait_response(first, 5_000)
    assert {:reply, 1} = :gen_server.wait_response(second, 5_000)
    assert GenServer.call(proxy, :get) == 1
  end

  test "on_unavailable: :error answers :noproc and keeps the proxy running", %{url: url} do
    proxy =
      start_supervised!({Proxy, url: url, contract: CounterContract, on_unavailable: :error})

    stop_supervised!(Counter)

    assert GenServer.call(proxy, :get) == {:error, :noproc}
    assert Process.alive?(proxy)

    start_supervised!(Counter)
    assert GenServer.call(proxy, :get) == 0
  end
end
