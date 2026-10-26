defmodule Snodo.OTP.ProxyTest do
  use ExUnit.Case, async: false

  alias Snodo.OTP.Proxy
  alias Snodo.Transport.StreamableHTTP.Server, as: HTTPServer
  alias SnodoTest.OTP.Counter
  alias SnodoTest.OTP.CounterContract
  alias SnodoTest.OTP.CounterServer

  setup do
    {:ok, counter} = start_supervised(Counter)

    {:ok, server} =
      start_supervised({HTTPServer, runtime: CounterServer.runtime(), port: 0})

    url = HTTPServer.url(server)
    {:ok, proxy} = start_supervised({Proxy, url: url, contract: CounterContract})
    %{counter: counter, server: server, url: url, proxy: proxy}
  end

  test "the contract exposes one tool per operation with its schemas", %{url: url} do
    {:ok, client} = Snodo.Client.connect({:http, url}, protocol: "2026-07-28")
    {:ok, tools} = Snodo.Client.list_tools(client)

    assert Enum.map(tools, & &1["name"]) |> Enum.sort() == [
             "counter_add",
             "counter_cast_add",
             "counter_get",
             "counter_slow"
           ]

    add = Enum.find(tools, &(&1["name"] == "counter_add"))
    assert add["inputSchema"]["required"] == ["by"]
    assert add["outputSchema"]["properties"]["value"]["type"] == "integer"
  end

  test "GenServer.call and GenServer.cast go over MCP unchanged", %{proxy: proxy} do
    assert GenServer.call(proxy, :get) == 0
    assert GenServer.call(proxy, {:add, 2}) == 2
    :ok = GenServer.cast(proxy, {:add, 3})
    assert eventually(fn -> GenServer.call(proxy, :get) == 5 end)
  end

  test "the caller's timeout governs and a late result is dropped, proxy stays alive", %{
    proxy: proxy
  } do
    assert catch_exit(GenServer.call(proxy, {:slow, 300}, 50)) |> elem(0) == :timeout
    Process.sleep(400)
    assert Process.alive?(proxy)
    assert GenServer.call(proxy, :get) == 0
  end

  test "a remote target that is gone stops the proxy with :noproc and DOWN reaches a monitor", %{
    proxy: proxy,
    counter: counter
  } do
    ref = Process.monitor(proxy)
    stop_supervised!(Counter)
    refute Process.alive?(counter)
    assert catch_exit(GenServer.call(proxy, :get)) |> elem(0) == :noproc
    assert_receive {:DOWN, ^ref, :process, ^proxy, :noproc}, 1_000
  end

  test "a dead endpoint stops the proxy with nodedown", %{url: url} do
    {:ok, proxy} = Proxy.start_link(url: url, contract: CounterContract)
    Process.unlink(proxy)
    ref = Process.monitor(proxy)
    stop_supervised!(HTTPServer)
    assert {reason, _} = catch_exit(GenServer.call(proxy, :get))
    assert {:nodedown, ^url} = reason
    assert_receive {:DOWN, ^ref, :process, ^proxy, {:nodedown, ^url}}, 1_000
  end

  test "a message outside the contract is a function clause stop, like an unmatched callback", %{
    proxy: proxy
  } do
    Process.unlink(proxy)
    assert {{:function_clause, :bogus}, _} = catch_exit(GenServer.call(proxy, :bogus))
  end

  test "the server-side adapter's own timeout surfaces as a tool error, not a proxy crash", %{
    url: url
  } do
    {:ok, client} = Snodo.Client.connect({:http, url}, protocol: "2026-07-28")
    {:ok, r} = Snodo.Client.call_tool(client, "counter_slow", %{"ms" => 800})
    assert r["isError"] == true
    assert [%{"text" => "GenServer call timed out"}] = r["content"]
  end

  defp eventually(fun, tries \\ 20) do
    cond do
      fun.() ->
        true

      tries == 0 ->
        false

      true ->
        Process.sleep(25)
        eventually(fun, tries - 1)
    end
  end
end
