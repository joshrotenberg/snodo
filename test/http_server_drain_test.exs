defmodule Snodo.Transport.StreamableHTTP.ServerDrainTest do
  use ExUnit.Case, async: true

  alias Snodo.Transport.StreamableHTTP.Server, as: HTTPServer
  alias SnodoTest.TestFixtures
  alias SnodoTest.TestSubscriptionHub
  alias SnodoTest.TestSubscriptionSource

  @protocol "2026-07-28"

  defmodule Gate do
    @moduledoc false
    use Snodo.Tool, name: "drain_gate"

    @impl true
    def call(%{"token" => token}, _context) do
      owner = :global.whereis_name({__MODULE__, token})
      send(owner, {:gate_entered, self()})

      receive do
        :release -> {:ok, Snodo.Result.text("released")}
      end
    end
  end

  test "an in-flight request completes during the drain; new connections are refused" do
    {server, port} = start_http(drain_timeout: 5_000)
    socket = call_gate(port)
    assert_receive {:gate_entered, handler}, 2_000

    stopper = stop_async(server)
    assert eventually(fn -> refused?(port) end)
    refute Task.yield(stopper, 50)

    send(handler, :release)
    response = read_all(socket)
    assert response =~ "HTTP/1.1 200"
    assert response =~ "released"
    assert Task.await(stopper, 2_000) == :ok
  end

  test "a connection whose request has not arrived gets 503 when the drain starts" do
    {server, port} = start_http(drain_timeout: 5_000)
    connection_supervisor = :sys.get_state(server).connection_supervisor
    socket = connect(port)
    :ok = :gen_tcp.send(socket, "POST /mcp HTTP/1.1\r\n")
    assert eventually(fn -> Task.Supervisor.children(connection_supervisor) != [] end)

    started = System.monotonic_time(:millisecond)
    stopper = stop_async(server)
    response = read_all(socket)
    assert response =~ "HTTP/1.1 503"
    assert %{"error" => %{"code" => -32_603, "message" => message}} = response_json(response)
    assert message == "Server is shutting down"
    assert Task.await(stopper, 2_000) == :ok
    assert System.monotonic_time(:millisecond) - started < 2_000
  end

  test "an open subscription stream gets its completion response" do
    {:ok, hub} = start_supervised({TestSubscriptionHub, owner: self()})

    runtime =
      TestFixtures.runtime(
        capabilities: %{"tools" => %{"listChanged" => true}},
        subscription_source: {TestSubscriptionSource, hub}
      )

    {server, port} = start_http(runtime: runtime, drain_timeout: 5_000)
    socket = connect(port)

    raw =
      TestFixtures.request("drained", "subscriptions/listen", %{
        "notifications" => %{"toolsListChanged" => true}
      })

    :ok = :gen_tcp.send(socket, request_parts(raw))
    streamed = recv_until(socket, "notifications/subscriptions/acknowledged")

    stopper = stop_async(server)
    streamed = streamed <> read_all(socket)
    assert_receive {:subscription_closed, "drained", :shutdown}, 2_000
    assert Task.await(stopper, 2_000) == :ok

    [final | _earlier] = streamed |> sse_messages() |> Enum.reverse()
    assert %{"id" => "drained", "result" => _result} = final
  end

  test "the drain timeout bounds a request that never finishes" do
    {server, port} = start_http(drain_timeout: 200, request_timeout: :infinity)
    socket = call_gate(port)
    assert_receive {:gate_entered, handler}, 2_000
    handler_monitor = Process.monitor(handler)

    started = System.monotonic_time(:millisecond)
    assert Task.await(stop_async(server), 5_000) == :ok
    elapsed = System.monotonic_time(:millisecond) - started

    assert elapsed >= 200
    assert elapsed < 3_000
    assert_receive {:DOWN, ^handler_monitor, :process, ^handler, _reason}, 2_000
    refute read_all(socket) =~ "HTTP/1.1"
  end

  @tag capture_log: true
  test "drain_timeout must be a positive integer" do
    runtime = TestFixtures.runtime()

    for value <- [0, -1, :infinity] do
      assert {:error, {{%ArgumentError{message: message}, _stack}, _child}} =
               start_supervised({HTTPServer, runtime: runtime, port: 0, drain_timeout: value})

      assert message == ":drain_timeout must be a positive integer"
    end
  end

  test "the child spec's shutdown exceeds the drain timeout" do
    assert %{shutdown: 10_000} = HTTPServer.child_spec(runtime: nil)
    assert %{shutdown: 65_000} = HTTPServer.child_spec(runtime: nil, drain_timeout: 60_000)
  end

  # The listener is linked to the test process rather than supervised, so a
  # test can stop it from another process and watch the drain from this one.
  defp start_http(options) do
    options = Keyword.put_new(options, :runtime, TestFixtures.runtime(tools: [Gate]))
    {:ok, server} = HTTPServer.start_link(Keyword.put(options, :port, 0))
    {_ip, port, _path} = HTTPServer.address(server)
    {server, port}
  end

  defp stop_async(server), do: Task.async(fn -> GenServer.stop(server) end)

  defp call_gate(port) do
    token = "gate-" <> Integer.to_string(System.unique_integer([:positive]))
    :yes = :global.register_name({Gate, token}, self())

    raw =
      TestFixtures.request(token, "tools/call", %{
        "name" => "drain_gate",
        "arguments" => %{"token" => token}
      })

    socket = connect(port)
    :ok = :gen_tcp.send(socket, request_parts(raw))
    socket
  end

  defp refused?(port) do
    case :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false]) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        false

      {:error, :econnrefused} ->
        true
    end
  end

  defp connect(port) do
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])
    socket
  end

  defp request_parts(raw) do
    body = JSON.encode!(raw)

    name =
      case raw do
        %{"params" => %{"name" => name}} -> [{"Mcp-Name", name}]
        _other -> []
      end

    headers =
      [
        {"Content-Type", "application/json"},
        {"Accept", "application/json, text/event-stream"},
        {"MCP-Protocol-Version", @protocol},
        {"Mcp-Method", raw["method"]}
      ] ++ name ++ [{"Content-Length", Integer.to_string(byte_size(body))}]

    lines = Enum.map(headers, fn {name, value} -> [name, ": ", value, "\r\n"] end)
    [IO.iodata_to_binary(["POST /mcp HTTP/1.1\r\n", lines, "\r\n"]), body]
  end

  defp read_all(socket, acc \\ "") do
    case :gen_tcp.recv(socket, 0, 2_000) do
      {:ok, chunk} -> read_all(socket, acc <> chunk)
      {:error, _closed_or_reset} -> acc
    end
  end

  defp recv_until(socket, pattern, acc \\ "") do
    if String.contains?(acc, pattern) do
      acc
    else
      case :gen_tcp.recv(socket, 0, 2_000) do
        {:ok, chunk} -> recv_until(socket, pattern, acc <> chunk)
        {:error, reason} -> flunk("closed before #{inspect(pattern)}: #{inspect(reason)}")
      end
    end
  end

  defp response_json(response) do
    [_head, body] = :binary.split(response, "\r\n\r\n")
    JSON.decode!(body)
  end

  defp sse_messages(response) do
    [_head, body] = :binary.split(response, "\r\n\r\n")

    for "data: " <> data <- String.split(body, "\r\n\r\n", trim: true) do
      JSON.decode!(data)
    end
  end

  defp eventually(check, deadline \\ System.monotonic_time(:millisecond) + 2_000) do
    cond do
      check.() ->
        true

      System.monotonic_time(:millisecond) > deadline ->
        false

      true ->
        Process.sleep(10)
        eventually(check, deadline)
    end
  end
end
