defmodule Snodo.OTP.ReviewFixesTest do
  use ExUnit.Case, async: false

  alias Snodo.OTP.Proxy
  alias Snodo.Transport.StreamableHTTP.Server, as: HTTPServer
  alias SnodoTest.OTP.Counter
  alias SnodoTest.OTP.CounterServer
  alias SnodoTest.OTP.FaultyContract

  setup do
    start_supervised!(Counter)
    server = start_supervised!({HTTPServer, runtime: CounterServer.runtime(), port: 0})
    url = HTTPServer.url(server)
    proxy = start_supervised!({Proxy, url: url, contract: FaultyContract})
    %{proxy: proxy, url: url}
  end

  test "a request process that crashes fails its call and later requests still run", %{
    proxy: proxy
  } do
    assert {:error, {:request_failed, _reason}} = GenServer.call(proxy, :unencodable)
    assert :sys.get_state(proxy).in_flight == nil
    assert GenServer.call(proxy, :get) == 0
  end

  test "a reply decode_reply does not match fails only its own call", %{proxy: proxy} do
    assert {:error, {:decode_failed, "counter_add", %{"value" => 1}}} =
             GenServer.call(proxy, :undecodable)

    assert GenServer.call(proxy, :get) == 1
  end

  test "a cast to a target that is not running is dropped, and the proxy stays up", %{
    proxy: proxy
  } do
    stop_supervised!(Counter)
    :ok = GenServer.cast(proxy, {:add, 1})
    assert eventually(fn -> :sys.get_state(proxy).in_flight == nil end)

    start_supervised!(Counter)
    assert GenServer.call(proxy, :get) == 0
    assert Process.alive?(proxy)
  end

  defp eventually(check, tries \\ 40) do
    cond do
      check.() -> true
      tries == 0 -> false
      true -> Process.sleep(25) && eventually(check, tries - 1)
    end
  end

  test ":connect options reach Snodo.Client.connect/2", %{url: url} do
    # The server enables only 2026-07-28, so an initialize-era pin cannot
    # connect, and the proxy stops as for any connection failure.
    {:ok, proxy} =
      Proxy.start_link(url: url, contract: FaultyContract, connect: [protocol: "2025-11-25"])

    Process.unlink(proxy)
    assert {{:nodedown, ^url}, _call} = catch_exit(GenServer.call(proxy, :get))
  end
end
