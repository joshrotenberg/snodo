defmodule Snodo.Transport.StreamableHTTP.ServerLimitsTest do
  use ExUnit.Case, async: true

  alias Snodo.Subscription.Hub
  alias Snodo.Transport.StreamableHTTP.Server, as: HTTPServer
  alias SnodoTest.SubscriptionWorker
  alias SnodoTest.TestFixtures
  alias SnodoTest.TestInstrumentationSink
  alias SnodoTest.TestSubscriptionHub
  alias SnodoTest.TestSubscriptionSource

  @protocol "2026-07-28"

  test "a body buffered with the complete head does not count against the header limit" do
    [head, body] = padded_request_parts("buffered")

    port =
      start_http(
        runtime: TestFixtures.runtime(),
        max_header_bytes: byte_size(head),
        max_body_bytes: byte_size(body)
      )

    assert byte_size(body) > byte_size(head)
    socket = connect(port)
    :ok = :gen_tcp.send(socket, [head, body])
    assert read_all(socket) =~ "HTTP/1.1 200"
  end

  test "a body buffered with the final head bytes does not count against the header limit" do
    [head, body] = padded_request_parts("split-head")

    port =
      start_http(
        runtime: TestFixtures.runtime(),
        max_header_bytes: byte_size(head),
        max_body_bytes: byte_size(body)
      )

    {prefix, suffix} = :erlang.split_binary(head, byte_size(head) - 2)
    socket = connect(port)
    :ok = :gen_tcp.send(socket, prefix)
    assert {:error, :timeout} = :gen_tcp.recv(socket, 0, 50)

    :ok = :gen_tcp.send(socket, [suffix, body])
    assert read_all(socket) =~ "HTTP/1.1 200"
  end

  test "the header limit includes the final CRLF" do
    [head, body] = request_parts(TestFixtures.request("large-head", "server/discover"))
    port = start_http(runtime: TestFixtures.runtime(), max_header_bytes: byte_size(head) - 1)
    socket = connect(port)
    :ok = :gen_tcp.send(socket, [head, body])
    assert read_all(socket) =~ "HTTP/1.1 431"
  end

  test "an incomplete head over the header limit gets 431" do
    port = start_http(runtime: TestFixtures.runtime(), max_header_bytes: 128)
    socket = connect(port)
    :ok = :gen_tcp.send(socket, "POST /mcp HTTP/1.1\r\nX-Fill: " <> String.duplicate("x", 129))
    assert read_all(socket) =~ "HTTP/1.1 431"
  end

  test "a buffered body larger than its own limit gets 413" do
    [head, body] = padded_request_parts("oversized-body")

    port =
      start_http(
        runtime: TestFixtures.runtime(),
        max_header_bytes: byte_size(head),
        max_body_bytes: byte_size(body) - 1
      )

    socket = connect(port)
    :ok = :gen_tcp.send(socket, [head, body])
    assert read_all(socket) =~ "HTTP/1.1 413"
  end

  test "a connection over max_connections is closed and capacity returns after a close" do
    port = start_http(runtime: TestFixtures.runtime(), max_connections: 2)
    raw = TestFixtures.request("capped", "server/discover")
    [head, body] = request_parts(raw)

    first = connect(port)
    :ok = :gen_tcp.send(first, head)
    second = connect(port)
    :ok = :gen_tcp.send(second, head)

    # Sockets are accepted in connect order, so this one arrives at the limit.
    third = connect(port)
    assert {:error, :closed} = :gen_tcp.recv(third, 0, 2_000)

    :ok = :gen_tcp.send(first, body)
    assert read_all(first) =~ "HTTP/1.1 200"

    assert eventually(fn -> served?(port, raw) end)

    :ok = :gen_tcp.send(second, body)
    assert read_all(second) =~ "HTTP/1.1 200"
  end

  test "a client that trickles the request head is closed at head_timeout" do
    port = start_http(runtime: TestFixtures.runtime(), head_timeout: 300, read_timeout: 1_000)
    # The head deadline runs from accept, which can complete before connect/3
    # returns here, so the clock starts before connecting.
    started = System.monotonic_time(:millisecond)
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: true])

    # Each byte arrives well inside :read_timeout, so only the head deadline
    # can end the connection.
    head = "POST /mcp HTTP/1.1\r\nX-Slow: " <> String.duplicate("a", 1_000)
    assert {:closed, _response} = trickle(socket, head, started + 5_000)

    elapsed = System.monotonic_time(:millisecond) - started
    assert elapsed >= 300
    assert elapsed < 3_000
  end

  test "a client that trickles the request body is closed at body_timeout" do
    runtime = TestFixtures.runtime()
    port = start_http(runtime: runtime, body_timeout: 300, read_timeout: 5_000)
    [head, body] = request_parts(TestFixtures.request("slow-body", "server/discover"))
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: true])
    # The body deadline runs from the end of the head, which the server can
    # read before send/2 returns here, so the clock starts before sending.
    started = System.monotonic_time(:millisecond)
    :ok = :gen_tcp.send(socket, head)

    # Each byte arrives well inside :read_timeout, and the whole body takes
    # seconds, so only the body deadline can end the request this early.
    assert {:closed, _response} = trickle(socket, body, started + 5_000)

    elapsed = System.monotonic_time(:millisecond) - started
    assert elapsed >= 300
    assert elapsed < 2_000
  end

  test "a body that arrives in parts before body_timeout is served" do
    port = start_http(runtime: TestFixtures.runtime(), body_timeout: 2_000)
    [head, body] = request_parts(TestFixtures.request("split-body", "server/discover"))
    socket = connect(port)
    :ok = :gen_tcp.send(socket, head)

    size = div(byte_size(body), 3)
    parts = [binary_part(body, 0, size), binary_part(body, size, size)]
    last = binary_part(body, 2 * size, byte_size(body) - 2 * size)

    # No response arrives while part of the body is still missing.
    for part <- parts do
      :ok = :gen_tcp.send(socket, part)
      assert {:error, :timeout} = :gen_tcp.recv(socket, 0, 50)
    end

    :ok = :gen_tcp.send(socket, last)
    assert read_all(socket) =~ "HTTP/1.1 200"
  end

  @tag capture_log: true
  test "limits must be positive integers" do
    runtime = TestFixtures.runtime()

    invalid = [
      max_connections: 0,
      head_timeout: -1,
      body_timeout: 0,
      max_subscriptions: :infinity
    ]

    for {key, value} <- invalid do
      assert {:error, {{%ArgumentError{message: message}, _stack}, _child}} =
               start_supervised({HTTPServer, [{key, value}, runtime: runtime, port: 0]})

      assert message == "#{inspect(key)} must be a positive integer"
    end
  end

  test "a stream over max_subscriptions gets 503; a close or crash frees a slot" do
    {:ok, hub} = start_supervised({TestSubscriptionHub, owner: self()})
    runtime = subscription_runtime({TestSubscriptionSource, hub})

    {:ok, server} =
      start_supervised({HTTPServer, runtime: runtime, port: 0, max_subscriptions: 1})

    {_ip, port, _path} = HTTPServer.address(server)
    executor = :sys.get_state(server).executor

    first = open_stream(port, "first")

    assert {:ok, response} = try_request(port, subscription_request("second"))
    assert response =~ "HTTP/1.1 503"
    assert %{"id" => "second", "error" => error} = response_json(response)
    assert error["message"] == "Server subscription capacity exhausted"
    assert_receive {:subscription_closed, "second", {:error, :overloaded}}, 1_000

    :ok = :gen_tcp.close(first)
    assert_receive {:subscription_closed, "first", _disconnected}, 1_000
    assert eventually(fn -> :sys.get_state(executor).slot_counts == %{} end)

    third = open_stream(port, "third")
    [holder] = slot_holders(executor)
    Process.exit(holder, :kill)
    assert eventually(fn -> :sys.get_state(executor).slot_counts == %{} end)
    assert_receive {:subscription_closed, "third", {:disconnected, reason}}, 1_000
    assert {:owner_down, _exit_reason} = reason

    fourth = open_stream(port, "fourth")
    assert {:ok, over} = try_request(port, subscription_request("fifth"))
    assert over =~ "HTTP/1.1 503"

    :gen_tcp.close(third)
    :gen_tcp.close(fourth)
  end

  test "a killed connection stops its subscription worker and closes the source" do
    hub = start_supervised!({Hub, instrumentation: {TestInstrumentationSink, self()}})
    runtime = subscription_runtime(Hub.source(hub))
    {:ok, server} = start_supervised({HTTPServer, runtime: runtime, port: 0})
    {_ip, port, _path} = HTTPServer.address(server)
    executor = :sys.get_state(server).executor

    socket = open_stream(port, "killed")
    [connection] = slot_holders(executor)
    worker = subscription_worker(connection)
    puller = SubscriptionWorker.puller(worker)
    monitors = SubscriptionWorker.monitor_confirmed([worker, puller])
    :ok = SubscriptionWorker.await_monitor(connection, worker)
    assert Hub.stats(hub).subscriptions == 1

    Process.exit(connection, :kill)

    for {pid, monitor} <- monitors do
      assert_receive {:DOWN, ^monitor, :process, ^pid, :shutdown}, 1_000
    end

    assert_receive {:instrumentation, [:snodo, :subscription, :close], %{subscriptions: 0},
                    %{reason: :disconnected}},
                   1_000

    assert Hub.stats(hub).subscriptions == 0
    :gen_tcp.close(socket)
  end

  test "an open stream does not retain a large unused request param" do
    hub = start_supervised!(Hub)
    runtime = subscription_runtime(Hub.source(hub))
    {:ok, server} = start_supervised({HTTPServer, runtime: runtime, port: 0})
    {_ip, port, _path} = HTTPServer.address(server)
    executor = :sys.get_state(server).executor

    raw =
      TestFixtures.request("large", "subscriptions/listen", %{
        "notifications" => %{
          "toolsListChanged" => true,
          "resourceSubscriptions" => ["test://resource/" <> String.duplicate("a", 100)]
        },
        "padding" => String.duplicate("x", 1_900_000)
      })

    socket = connect(port)
    :ok = :gen_tcp.send(socket, request_parts(raw))
    _acknowledgement = recv_until(socket, "notifications/subscriptions/acknowledged")

    [connection] = slot_holders(executor)
    worker = subscription_worker(connection)
    puller = SubscriptionWorker.puller(worker)

    for pid <- [connection, worker, puller, hub] do
      assert large_binaries(pid) == []
    end

    :gen_tcp.close(socket)
  end

  defp start_http(options) do
    {:ok, server} = start_supervised({HTTPServer, Keyword.put(options, :port, 0)})
    {_ip, port, _path} = HTTPServer.address(server)
    port
  end

  defp subscription_runtime(source) do
    TestFixtures.runtime(
      capabilities: %{
        "tools" => %{"listChanged" => true},
        "resources" => %{"subscribe" => true}
      },
      subscription_source: source
    )
  end

  defp subscription_request(id) do
    TestFixtures.request(id, "subscriptions/listen", %{
      "notifications" => %{"toolsListChanged" => true}
    })
  end

  defp open_stream(port, id) do
    socket = connect(port)
    :ok = :gen_tcp.send(socket, request_parts(subscription_request(id)))
    _acknowledgement = recv_until(socket, "notifications/subscriptions/acknowledged")
    socket
  end

  # The processes the executor monitors while no request is running are the
  # connections holding subscription slots.
  defp slot_holders(executor) do
    {:monitors, monitors} = Process.info(executor, :monitors)
    for {:process, pid} <- monitors, do: pid
  end

  # The connection also monitors its socket port; the worker is the one process.
  defp subscription_worker(connection) do
    {:monitors, monitors} = Process.info(connection, :monitors)
    [worker] = for {:process, pid} <- monitors, do: pid
    worker
  end

  defp large_binaries(pid) do
    true = :erlang.garbage_collect(pid)
    {:binary, binaries} = Process.info(pid, :binary)
    for {_id, size, _references} <- binaries, size >= 1_000_000, do: size
  end

  defp connect(port) do
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])
    socket
  end

  defp request_parts(raw) do
    body = JSON.encode!(raw)

    headers = [
      {"Content-Type", "application/json"},
      {"Accept", "application/json, text/event-stream"},
      {"MCP-Protocol-Version", @protocol},
      {"Mcp-Method", raw["method"]},
      {"Content-Length", Integer.to_string(byte_size(body))}
    ]

    lines = Enum.map(headers, fn {name, value} -> [name, ": ", value, "\r\n"] end)
    [IO.iodata_to_binary(["POST /mcp HTTP/1.1\r\n", lines, "\r\n"]), body]
  end

  defp padded_request_parts(id) do
    TestFixtures.request(id, "server/discover", %{"padding" => String.duplicate("x", 12_000)})
    |> request_parts()
  end

  # A socket closed at accept can be reset rather than closed when the request
  # was already sent, and then no response arrives.
  defp try_request(port, raw) do
    socket = connect(port)

    case :gen_tcp.send(socket, request_parts(raw)) do
      :ok ->
        case read_all(socket) do
          "" -> :closed
          response -> {:ok, response}
        end

      {:error, _reason} ->
        :closed
    end
  end

  defp served?(port, raw), do: match?({:ok, "HTTP/1.1 200" <> _rest}, try_request(port, raw))

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

  defp trickle(_socket, "", _deadline), do: {:open, ""}

  defp trickle(socket, <<byte, rest::binary>>, deadline) do
    if System.monotonic_time(:millisecond) > deadline do
      {:open, ""}
    else
      _sent = :gen_tcp.send(socket, <<byte>>)

      receive do
        {:tcp, ^socket, data} -> await_close(socket, data)
        {:tcp_closed, ^socket} -> {:closed, ""}
        {:tcp_error, ^socket, _reason} -> {:closed, ""}
      after
        20 -> trickle(socket, rest, deadline)
      end
    end
  end

  defp await_close(socket, acc) do
    receive do
      {:tcp, ^socket, data} -> await_close(socket, acc <> data)
      {:tcp_closed, ^socket} -> {:closed, acc}
      {:tcp_error, ^socket, _reason} -> {:closed, acc}
    after
      2_000 -> {:open, acc}
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
