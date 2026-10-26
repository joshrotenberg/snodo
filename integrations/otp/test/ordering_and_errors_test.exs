defmodule Snodo.OTP.OrderingAndErrorsTest do
  use ExUnit.Case, async: false

  alias Snodo.OTP.Proxy
  alias Snodo.Transport.StreamableHTTP.Server, as: HTTPServer
  alias SnodoTest.OTP.Recorder
  alias SnodoTest.OTP.RecorderContract
  alias SnodoTest.OTP.RecorderServer

  setup do
    start_supervised!(Recorder)
    server = start_supervised!({HTTPServer, runtime: RecorderServer.runtime(), port: 0})
    url = HTTPServer.url(server)
    proxy = start_supervised!({Proxy, url: url, contract: RecorderContract})
    %{proxy: proxy, url: url}
  end

  test "casts from one sender reach the remote GenServer in order", %{proxy: proxy} do
    for n <- 1..30, do: GenServer.cast(proxy, {:push, n})
    assert GenServer.call(proxy, :list) == Enum.to_list(1..30)
  end

  test "a call sees every cast its sender sent before it", %{proxy: proxy} do
    for n <- 1..20 do
      GenServer.cast(proxy, {:push, n})
      assert n in GenServer.call(proxy, :list)
    end
  end

  test "a remote timeout answers {:error, :timeout}, also to an :infinity caller", %{
    proxy: proxy
  } do
    assert GenServer.call(proxy, {:slow, 300}, :infinity) == {:error, :timeout}
    assert GenServer.call(proxy, :list) == []
  end

  test "the proxy's own request timeout answers {:error, :timeout} and keeps it running", %{
    url: url
  } do
    {:ok, proxy} = Proxy.start_link(url: url, contract: RecorderContract, request_timeout: 100)
    assert GenServer.call(proxy, {:slow_long, 500}, :infinity) == {:error, :timeout}
    assert Process.alive?(proxy)

    # The remote GenServer is still busy with that call for a while.
    Process.sleep(500)
    assert GenServer.call(proxy, :list) == []
  end

  test "an HTTP error status is answered as an error and the proxy keeps running", %{url: url} do
    {:ok, proxy} = Proxy.start_link(url: url <> "-missing", contract: RecorderContract)

    assert {:error, %Snodo.Error{kind: :transport, cause: {:http_status, 404, _body}}} =
             GenServer.call(proxy, :list)

    assert Process.alive?(proxy)
  end
end
