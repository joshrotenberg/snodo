defmodule Snodo.Transport.PlugBanditTest do
  use ExUnit.Case, async: true

  alias Snodo.Server.Executor
  alias Snodo.Subscription.Hub
  alias SnodoTest.PlugFixtures
  alias SnodoTest.PlugFixtures.Policy
  alias SnodoTest.PlugFixtures.Probe
  alias SnodoTest.PlugFixtures.Tool

  defmodule HubObserver do
    @moduledoc false
    @behaviour Snodo.Instrumentation

    @impl true
    def handle_event(name, measurements, metadata, owner) do
      send(owner, {:hub_event, name, measurements, metadata})
      :ok
    end
  end

  @protocol "2026-07-28"
  @version_key "io.modelcontextprotocol/protocolVersion"
  @capabilities_key "io.modelcontextprotocol/clientCapabilities"

  test "real Bandit dispatches discovery and forwards only trusted authentication" do
    %{port: port} = server()
    assert {200, discovery} = rpc(port, request("server/discover", %{}))
    assert @protocol in discovery["result"]["supportedVersions"]

    body =
      request("tools/call", %{
        "name" => "inspect_context",
        "arguments" => %{"text" => "hello", "auth" => "admin"}
      })

    assert {200, result} = rpc(port, body, auth: :alpha)
    assert result["result"]["structuredContent"] == %{"principal" => "alpha", "text" => "hello"}
    assert {200, anonymous} = rpc(port, body, headers: [{"x-user", "admin"}])
    assert anonymous["result"]["structuredContent"]["principal"] == nil
  end

  test "application authorization filters discovery and refuses calls below the Plug boundary" do
    %{port: port} =
      server(
        tools: [Tool, Probe],
        authorization:
          {Policy,
           %{
             owner: self(),
             allowed: %{
               "alpha" => ["inspect_context"],
               "beta" => ["probe_side_effect"]
             }
           }}
      )

    listed = request("tools/list", %{})
    assert {200, alpha} = rpc(port, listed, auth: :alpha)
    assert Enum.map(alpha["result"]["tools"], & &1["name"]) == ["inspect_context"]
    assert {200, beta} = rpc(port, listed, auth: :beta)
    assert Enum.map(beta["result"]["tools"], & &1["name"]) == ["probe_side_effect"]
    assert {200, anonymous} = rpc(port, listed)
    assert anonymous["result"]["tools"] == []

    probe = request("tools/call", %{"name" => "probe_side_effect", "arguments" => %{}})

    # A refusal is an application error inside a 200; HTTP-level authentication
    # stays in the application's own Plug pipeline.
    assert {200, refused} = rpc(port, probe, auth: :alpha)
    assert refused["error"]["code"] == -32_003
    assert_receive {:authorization_refused, "alpha", "probe_side_effect"}, 1_000
    refute_receive :probe_side_effect_ran, 50

    assert {200, allowed} = rpc(port, probe, auth: :beta)
    assert allowed["result"]["content"] == [%{"type" => "text", "text" => "ran"}]
    assert_receive :probe_side_effect_ran, 1_000
  end

  test "HTTP path, media, origin and mirrored headers are admitted before handlers" do
    %{port: port, executor: executor} = server()
    body = request("tools/call", %{"name" => "inspect_context", "arguments" => %{}})

    for {opts, status} <- [
          {[path: "/elsewhere"], 404},
          {[method: "GET"], 405},
          {[replace_headers: [{"content-type", "text/plain"}]], 415},
          {[replace_headers: [{"accept", "application/json"}]], 406},
          {[headers: [{"origin", "https://evil.invalid"}]], 403},
          {[replace_headers: [{"mcp-name", "different"}]], 400},
          {[headers: [{"mcp-protocol-version", @protocol}]], 400}
        ] do
      assert {^status, _body} = rpc(port, body, opts)
    end

    refute_receive {:tool_entered, _id, _worker, _token}, 20
    assert %{running: 0, queued: 0} = Executor.stats(executor)
    assert {200, _result} = rpc(port, body, headers: [{"origin", "http://localhost:9999"}])
  end

  test "refuses duplicate JSON keys in a raw Plug request" do
    %{port: port} = server()
    {head, _encoded} = http_request(request("server/discover", %{}))
    body = ~s({"jsonrpc":"2.0","id":1,"method":"server/discover","params":{"a":1,"a":2}})
    head = String.replace(head, ~r/content-length: \d+/, "content-length: #{byte_size(body)}")
    socket = connect(port)
    :ok = :gen_tcp.send(socket, [head, body])
    [response_head, response_body] = String.split(read_all(socket), "\r\n\r\n", parts: 2)

    assert response_head =~ "HTTP/1.1 400"
    assert %{"id" => nil, "error" => %{"code" => -32_700}} = JSON.decode!(response_body)
  end

  test "legacy session headers are ignored and never echoed by the modern binding" do
    %{port: port} = server()
    socket = connect(port)
    send_rpc(socket, request("server/discover", %{}), headers: [{"mcp-session-id", "legacy"}])
    raw = read_all(socket)
    assert raw =~ "HTTP/1.1 200"
    refute String.downcase(raw) =~ "mcp-session-id"
  end

  test "raw body limit rejects an oversized body and closes the connection" do
    %{port: port} = server(max_body_bytes: 64)
    socket = connect(port)
    # A keep-alive request: only the response can close the connection.
    {head, body} = http_request(request("server/discover", %{}), keep_alive: true)
    :ok = :gen_tcp.send(socket, [head, body])
    raw = read_all(socket)
    assert raw =~ "HTTP/1.1 413"
    assert raw =~ "connection: close"
  end

  test "a chunked request gets 411 without its body being read" do
    %{port: port} = server()
    socket = connect(port)
    {head, _body} = http_request(request("server/discover", %{}), keep_alive: true)
    head = String.replace(head, ~r/content-length: \d+/, "transfer-encoding: chunked")

    # The body never ends. Unless the response closes the connection, Bandit
    # waits for the rest of it after the Plug returns.
    :ok = :gen_tcp.send(socket, [head, "5\r\nhello\r\n"])

    raw = read_all(socket)
    assert raw =~ "HTTP/1.1 411"
    assert raw =~ "connection: close"
  end

  @tag capture_log: true
  test "a trickled Content-Length body gets 408 at body_timeout" do
    %{port: port} = server(body_timeout: 300, read_timeout: 5_000)
    socket = connect(port)
    {head, body} = http_request(request("server/discover", %{}))
    :ok = :gen_tcp.send(socket, head)
    started = System.monotonic_time(:millisecond)

    # Each byte arrives well inside read_timeout and the whole body takes
    # seconds, so only the body deadline can answer this early.
    raw = trickle(socket, body, 20)
    elapsed = System.monotonic_time(:millisecond) - started

    assert raw =~ "HTTP/1.1 408"
    assert raw =~ "connection: close"
    assert elapsed >= 300
    assert elapsed < 2_000
  end

  test "a body that arrives in parts before body_timeout is served" do
    %{port: port} = server(body_timeout: 2_000)
    socket = connect(port)
    # Several read slices, so the Plug reads the body in more than one call.
    padding = String.duplicate("x", 200_000)
    {head, body} = http_request(request("server/discover", %{"padding" => padding}))
    :ok = :gen_tcp.send(socket, head)

    size = div(byte_size(body), 3)
    parts = [binary_part(body, 0, size), binary_part(body, size, size)]
    last = binary_part(body, 2 * size, byte_size(body) - 2 * size)

    # No response arrives while part of the body is still missing.
    for part <- parts do
      :ok = :gen_tcp.send(socket, part)
      assert {:error, :timeout} = :gen_tcp.recv(socket, 0, 100)
    end

    :ok = :gen_tcp.send(socket, last)
    assert read_all(socket) =~ "HTTP/1.1 200"
  end

  test "an HTTP/2 request is served" do
    %{port: port} = server()
    # Several read slices, in frames no larger than the default maximum.
    padding = String.duplicate("x", 200_000)
    encoded = JSON.encode!(request("server/discover", %{"padding" => padding}))
    socket = h2_open(port, h2_headers("server/discover", byte_size(encoded)))
    frames = for <<frame::binary-size(16_384) <- encoded>>, do: h2_frame(:data, [], frame)
    last = binary_part(encoded, length(frames) * 16_384, rem(byte_size(encoded), 16_384))
    :ok = :gen_tcp.send(socket, [frames, h2_frame(:data, [:end_stream], last)])

    assert {"200", _headers, body} = h2_response(socket)
    assert @protocol in JSON.decode!(body)["result"]["supportedVersions"]
  end

  test "an HTTP/2 body that stops arriving gets 408 at body_timeout" do
    %{port: port} = server(body_timeout: 300, read_timeout: 5_000)
    encoded = JSON.encode!(request("server/discover", %{}))
    socket = h2_open(port, h2_headers("server/discover", byte_size(encoded)))
    started = System.monotonic_time(:millisecond)
    :ok = :gen_tcp.send(socket, h2_frame(:data, [], binary_part(encoded, 0, 10)))

    assert {"408", headers, ""} = h2_response(socket)
    elapsed = System.monotonic_time(:millisecond) - started
    # HTTP/2 forbids connection-specific headers.
    refute List.keymember?(headers, "connection", 0)
    assert elapsed >= 300
    assert elapsed < 2_000
  end

  test "body_timeout must be a positive integer" do
    runtime = PlugFixtures.runtime(start_supervised!(Hub))

    for value <- [0, -1, :infinity] do
      assert_raise ArgumentError, ":body_timeout must be a positive integer", fn ->
        Snodo.Transport.Plug.init(runtime: runtime, executor: self(), body_timeout: value)
      end
    end
  end

  test "overload is bounded and cancellation bypasses a saturated executor without crossing principals" do
    %{port: port, executor: executor} = server(max_concurrency: 1, max_queue: 0)
    pending = connect(port)

    send_rpc(
      pending,
      request("tools/call", %{"name" => "inspect_context", "arguments" => %{"wait" => true}}, 77),
      auth: :alpha
    )

    assert_receive {:tool_entered, 77, worker, token}, 1_000
    monitor = Process.monitor(worker)
    assert {503, _result} = rpc(port, request("server/discover", %{}))

    notification = cancellation(77)
    assert {202, nil} = rpc(port, notification, auth: :beta)
    assert {202, nil} = rpc(port, notification)
    refute Snodo.Cancellation.cancelled?(token)
    assert Process.alive?(worker)
    assert %{running: 1, queued: 0} = Executor.stats(executor)

    assert {202, nil} = rpc(port, notification, auth: :alpha)
    assert_receive {:DOWN, ^monitor, :process, ^worker, _reason}, 1_000
    assert Snodo.Cancellation.cancelled?(token)
    assert read_all(pending) =~ "HTTP/1.1 204"
    assert {200, _result} = rpc(port, request("server/discover", %{}))
  end

  test "malformed cancellation cannot cancel an authenticated execution" do
    %{port: port} = server(max_concurrency: 1, max_queue: 0)
    pending = connect(port)

    send_rpc(
      pending,
      request("tools/call", %{"name" => "inspect_context", "arguments" => %{"wait" => true}}, 78),
      auth: :alpha
    )

    assert_receive {:tool_entered, 78, worker, token}, 1_000
    malformed = put_in(cancellation(78), ["params", "reason"], 42)
    assert {202, nil} = rpc(port, malformed, auth: :alpha)
    refute Snodo.Cancellation.cancelled?(token)
    assert Process.alive?(worker)
    assert {202, nil} = rpc(port, cancellation(78), auth: :alpha)
    assert read_all(pending) =~ "HTTP/1.1 204"
  end

  test "finite request deadline cleans up work after an idle peer disconnect" do
    %{port: port, executor: executor} = server(request_timeout: 120)
    socket = connect(port)

    send_rpc(
      socket,
      request("tools/call", %{"name" => "inspect_context", "arguments" => %{"wait" => true}}, 80),
      auth: :alpha
    )

    assert_receive {:tool_entered, 80, worker, token}, 1_000
    monitor = Process.monitor(worker)
    :ok = :gen_tcp.close(socket)
    assert_receive {:DOWN, ^monitor, :process, ^worker, _reason}, 1_000
    assert Snodo.Cancellation.cancelled?(token)
    assert eventually(fn -> Executor.stats(executor).running == 0 end)
  end

  test "a client disconnect cancels a silent handler before the request deadline" do
    %{port: port, executor: executor} = server(request_timeout: 30_000, disconnect_probe_ms: 50)
    socket = connect(port)

    send_rpc(
      socket,
      request("tools/call", %{"name" => "inspect_context", "arguments" => %{"wait" => true}}, 83),
      auth: :alpha
    )

    assert_receive {:tool_entered, 83, worker, token}, 1_000
    monitor = Process.monitor(worker)
    :ok = :gen_tcp.close(socket)
    assert_receive {:DOWN, ^monitor, :process, ^worker, _reason}, 2_000
    assert Snodo.Cancellation.cancelled?(token)
    assert eventually(fn -> Executor.stats(executor).running == 0 end)
  end

  test "a handler that outlasts the probe returns its result as the final event" do
    %{port: port} = server(disconnect_probe_ms: 50)
    socket = connect(port)
    arguments = %{"sleep_ms" => 300, "text" => "slow"}

    send_rpc(
      socket,
      request("tools/call", %{"name" => "inspect_context", "arguments" => arguments}, 84),
      auth: :alpha
    )

    raw = read_all(socket)
    assert raw =~ "HTTP/1.1 200"
    assert String.downcase(raw) =~ "content-type: text/event-stream"
    assert raw =~ ": keepalive"

    assert [%{"id" => 84, "result" => %{"structuredContent" => %{"text" => "slow"}}}] =
             sse_messages(raw)
  end

  test ":infinity keeps a plain JSON response for a slow handler" do
    %{port: port} = server(disconnect_probe_ms: :infinity)
    arguments = %{"sleep_ms" => 150, "text" => "json"}
    body = request("tools/call", %{"name" => "inspect_context", "arguments" => arguments}, 85)

    assert {200, %{"id" => 85, "result" => %{"structuredContent" => %{"text" => "json"}}}} =
             rpc(port, body, auth: :alpha)
  end

  test "queue wait is included in the finite request deadline" do
    %{port: port, executor: executor} =
      server(max_concurrency: 1, max_queue: 1, request_timeout: 60)

    assert {:ok, _reference} =
             Executor.submit(
               executor,
               :external_blocker,
               fn _token -> Process.sleep(:infinity) end,
               timeout: :infinity
             )

    body = request("tools/call", %{"name" => "inspect_context", "arguments" => %{}}, 81)
    assert {504, _error} = rpc(port, body, auth: :alpha)
    refute_receive {:tool_entered, 81, _worker, _token}, 20
    assert eventually(fn -> Executor.stats(executor).queued == 0 end)
    assert :ok = Executor.cancel(executor, :external_blocker)
  end

  test "ordinary progress switches to SSE and precedes the terminal result" do
    %{port: port} = server()
    socket = connect(port)
    body = progressing_request(90, %{"progress" => true, "text" => "complete"})
    send_rpc(socket, body, auth: :alpha)
    raw = read_all(socket)
    assert raw =~ "content-type: text/event-stream"
    messages = sse_messages(raw)

    assert [
             %{
               "method" => "notifications/progress",
               "params" => %{"progress" => 1, "progressToken" => "progress-90"}
             },
             %{"method" => "notifications/progress", "params" => %{"progress" => 2}},
             %{"id" => 90, "result" => %{"structuredContent" => %{"text" => "complete"}}}
           ] = messages

    assert_receive {:progress_replies, :ok, :ok}
  end

  test "without a progress token the same handler remains a complete JSON response" do
    %{port: port} = server()

    body =
      request("tools/call", %{"name" => "inspect_context", "arguments" => %{"progress" => true}})

    assert {200, %{"result" => _result}} = rpc(port, body, auth: :alpha)
    assert_receive {:progress_replies, :ok, :ok}
  end

  test "malformed progress metadata fails before handler invocation" do
    %{port: port} = server()

    body =
      put_in(
        progressing_request(91, %{"progress" => true}),
        ["params", "_meta", "progressToken"],
        %{}
      )

    assert {400, %{"error" => %{"code" => -32_602}}} = rpc(port, body, auth: :alpha)
    refute_receive {:tool_entered, 91, _worker, _token}, 20
  end

  test "progress keepalive failure cancels silent work after the first progress frames" do
    %{port: port, executor: executor} =
      server(request_timeout: 10_000, subscription_keepalive_ms: 20)

    socket = connect(port)

    body = progressing_request(92, %{"progress" => true, "wait_after_progress" => true})
    send_rpc(socket, body, auth: :alpha)

    assert_receive {:tool_entered, 92, worker, token}, 1_000
    monitor = Process.monitor(worker)
    _progress = read_until(socket, "notifications/progress")
    assert_receive {:progress_replies, :ok, :ok}, 1_000
    :ok = :gen_tcp.close(socket)
    assert_receive {:DOWN, ^monitor, :process, ^worker, _reason}, 1_000
    assert Snodo.Cancellation.cancelled?(token)
    assert eventually(fn -> Executor.stats(executor).running == 0 end)
  end

  test "a timeout after progress is a terminal SSE error rather than a second HTTP response" do
    %{port: port} = server(request_timeout: 80, subscription_keepalive_ms: 20)
    socket = connect(port)

    body = progressing_request(93, %{"progress" => true, "wait_after_progress" => true})
    send_rpc(socket, body, auth: :alpha)

    raw = read_all(socket)
    assert raw =~ "HTTP/1.1 200"
    refute raw =~ "HTTP/1.1 504"
    assert %{"id" => 93, "error" => %{"code" => -32_603}} = List.last(sse_messages(raw))
  end

  @tag capture_log: true
  test "abrupt Plug owner death cancels an ordinary execution" do
    %{port: port, executor: executor} = server(request_timeout: 10_000)
    socket = connect(port)

    send_rpc(
      socket,
      request("tools/call", %{"name" => "inspect_context", "arguments" => %{"wait" => true}}, 82),
      auth: :alpha
    )

    assert_receive {:plug_owner, owner}, 1_000
    assert_receive {:tool_entered, 82, worker, token}, 1_000
    monitor = Process.monitor(worker)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^worker, _reason}, 1_000
    assert Snodo.Cancellation.cancelled?(token)
    assert eventually(fn -> Executor.stats(executor).running == 0 end)
    :gen_tcp.close(socket)
  end

  test "SSE acknowledges before updates and completes with the original ID" do
    %{port: port, hub: hub} = server()
    socket = connect(port)
    send_rpc(socket, subscription("subscription-1"))
    first = read_until(socket, "notifications/subscriptions/acknowledged")
    assert first =~ "content-type: text/event-stream"
    refute first =~ "notifications/tools/list_changed"
    assert {200, _discovery} = rpc(port, request("server/discover", %{}))
    assert {:ok, %{matched: 1}} = Hub.notify_tools_list_changed(hub)
    update = read_until(socket, "notifications/tools/list_changed")
    assert update =~ "subscription-1"
    assert :ok = Hub.complete(hub)
    final = read_all(socket)
    assert final =~ "\"resultType\":\"complete\""
    assert final =~ "\"id\":\"subscription-1\""
    assert eventually(fn -> Hub.stats(hub).subscriptions == 0 end)
  end

  test "idle SSE keepalives detect a closed socket and release the subscription" do
    %{port: port, hub: hub} = server(subscription_keepalive_ms: 20)
    socket = connect(port)
    send_rpc(socket, subscription("idle"))
    _ack = read_until(socket, "notifications/subscriptions/acknowledged")
    assert read_until(socket, ": keepalive") =~ ": keepalive"
    :ok = :gen_tcp.close(socket)
    assert eventually(fn -> Hub.stats(hub).subscriptions == 0 end)
  end

  @tag capture_log: true
  test "abrupt Plug owner death closes a blocked subscription pull" do
    %{port: port, hub: hub} = server(subscription_keepalive_ms: 10_000)
    socket = connect(port)
    send_rpc(socket, subscription("owner-death"))
    assert_receive {:plug_owner, owner}, 1_000
    _ack = read_until(socket, "notifications/subscriptions/acknowledged")
    assert Hub.stats(hub).subscriptions == 1
    Process.exit(owner, :kill)
    assert eventually(fn -> Hub.stats(hub).subscriptions == 0 end)
    :gen_tcp.close(socket)
  end

  test "a stream over max_subscriptions gets 503; a disconnect or crash frees a slot" do
    %{port: port, hub: hub, executor: executor} =
      server(max_subscriptions: 1, subscription_keepalive_ms: 20)

    first = open_stream(port, "first")
    assert {503, %{"id" => "second", "error" => error}} = rpc(port, subscription("second"))
    assert error["message"] == "Server subscription capacity exhausted"
    assert Hub.stats(hub).subscriptions == 1

    :ok = :gen_tcp.close(first)
    assert eventually(fn -> :sys.get_state(executor).slot_counts == %{} end)

    third = open_stream(port, "third")
    [stream] = slot_holders(executor)
    Process.exit(stream, :kill)
    assert eventually(fn -> :sys.get_state(executor).slot_counts == %{} end)
    assert eventually(fn -> Hub.stats(hub).subscriptions == 0 end)

    fourth = open_stream(port, "fourth")
    assert {503, _result} = rpc(port, subscription("fifth"))

    :gen_tcp.close(third)
    :gen_tcp.close(fourth)
  end

  @tag capture_log: true
  test "a stream closes when its supervised executor restarts" do
    name = :snodo_plug_restart_test_executor

    %{port: port, hub: hub, executor: executor} =
      server(max_subscriptions: 1, executor_name: name, subscription_keepalive_ms: 20)

    first = open_stream(port, "before-restart")
    [stream] = slot_holders(executor)
    stream_monitor = Process.monitor(stream)

    Process.exit(executor, :kill)

    assert_receive {:DOWN, ^stream_monitor, :process, ^stream, :normal}, 1_000
    assert eventually(fn -> Hub.stats(hub).subscriptions == 0 end)
    assert eventually(fn -> Process.whereis(name) not in [nil, executor] end)

    second = open_stream(port, "after-restart")
    assert {503, _error} = rpc(port, subscription("over-limit"))

    :gen_tcp.close(first)
    :gen_tcp.close(second)
  end

  test "a killed stream process stops its subscription worker and closes the source" do
    %{port: port, hub: hub, executor: executor} =
      server(subscription_keepalive_ms: 20, hub_instrumentation: {HubObserver, self()})

    socket = open_stream(port, "killed")
    [stream] = slot_holders(executor)
    worker = :sys.get_state(stream).worker
    puller = puller(worker)
    monitors = monitor_confirmed([worker, puller])
    :ok = await_monitor(stream, worker)
    assert Hub.stats(hub).subscriptions == 1

    Process.exit(stream, :kill)

    for {pid, monitor} <- monitors do
      assert_receive {:DOWN, ^monitor, :process, ^pid, :shutdown}, 1_000
    end

    assert_receive {:hub_event, [:snodo, :subscription, :close], %{subscriptions: 0},
                    %{reason: :disconnected}},
                   1_000

    assert Hub.stats(hub).subscriptions == 0
    :gen_tcp.close(socket)
  end

  test "an open stream does not retain a large unused request param" do
    %{port: port, hub: hub, executor: executor} = server(subscription_keepalive_ms: 20)
    socket = connect(port)

    body =
      request(
        "subscriptions/listen",
        %{
          "notifications" => %{"toolsListChanged" => true},
          "padding" => String.duplicate("x", 1_900_000)
        },
        "large"
      )

    send_rpc(socket, body)
    assert_receive {:plug_owner, owner}, 1_000
    _ack = read_until(socket, "notifications/subscriptions/acknowledged")
    [stream] = slot_holders(executor)
    worker = :sys.get_state(stream).worker
    puller = puller(worker)

    for pid <- [owner, stream, worker, puller, hub] do
      assert large_binaries(pid) == []
    end

    :ok = :gen_tcp.close(socket)
    assert eventually(fn -> Hub.stats(hub).subscriptions == 0 end)
  end

  for version <- ["2025-06-18", "2025-11-25"] do
    @legacy_version version

    test "#{version} native HTTP lifecycle omits sessions and modern mirrored headers" do
      %{port: port} =
        server(
          capabilities: %{"tools" => %{}},
          protocols: [
            Snodo.Protocol.V2026_07_28,
            Snodo.Protocol.V2025_11_25,
            Snodo.Protocol.V2025_06_18
          ]
        )

      initialize = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => @legacy_version,
          "capabilities" => %{},
          "clientInfo" => %{"name" => "fixture", "version" => "1"}
        }
      }

      socket = connect(port)
      send_rpc(socket, initialize, legacy: true)
      raw = read_all(socket)
      assert raw =~ "HTTP/1.1 200"
      refute String.downcase(raw) =~ "mcp-session-id"
      [_, encoded] = String.split(raw, "\r\n\r\n", parts: 2)
      result = JSON.decode!(encoded)["result"]
      assert result["protocolVersion"] == @legacy_version
      assert result["capabilities"] == %{"tools" => %{}}
      options = [legacy: true, headers: [{"mcp-protocol-version", @legacy_version}]]
      initialized = %{"jsonrpc" => "2.0", "method" => "notifications/initialized"}
      assert {202, nil} = rpc(port, initialized, options)
      listed = %{"jsonrpc" => "2.0", "id" => 2, "method" => "tools/list"}

      assert {200, %{"result" => %{"tools" => [%{"name" => "inspect_context"}]}}} =
               rpc(port, listed, options)

      called = %{
        "jsonrpc" => "2.0",
        "id" => 3,
        "method" => "tools/call",
        "params" => %{
          "name" => "inspect_context",
          "arguments" => %{"text" => "legacy"}
        }
      }

      for principal <- [:alpha, :beta, :alpha] do
        expected = to_string(principal)

        assert {200, %{"result" => %{"structuredContent" => %{"principal" => ^expected}}}} =
                 rpc(port, called, Keyword.put(options, :auth, principal))
      end

      unknown_tool = %{
        "jsonrpc" => "2.0",
        "id" => 4,
        "method" => "tools/call",
        "params" => %{"name" => "missing", "arguments" => %{}}
      }

      assert {200, %{"id" => 4, "error" => %{"code" => -32_602}}} =
               rpc(port, unknown_tool, options)

      unknown_method = %{
        "jsonrpc" => "2.0",
        "id" => 5,
        "method" => "logging/setLevel",
        "params" => %{"level" => "info"}
      }

      assert {200, %{"id" => 5, "error" => %{"code" => -32_601}}} =
               rpc(port, unknown_method, options)

      assert {400, _} = rpc(port, listed, legacy: true)

      assert {400, _} =
               rpc(port, listed, legacy: true, headers: [{"mcp-protocol-version", "1900-01-01"}])

      assert {400, _} =
               rpc(port, listed,
                 legacy: true,
                 headers: [
                   {"mcp-protocol-version", @legacy_version},
                   {"mcp-protocol-version", @legacy_version}
                 ]
               )

      assert {405, _} = rpc(port, listed, Keyword.put(options, :method, "GET"))
      assert {405, _} = rpc(port, listed, Keyword.put(options, :method, "DELETE"))
    end

    test "#{version} request progress uses SSE before the legacy result" do
      %{port: port} =
        server(
          capabilities: %{"tools" => %{}},
          protocols: [Snodo.Protocol.V2025_11_25, Snodo.Protocol.V2025_06_18]
        )

      socket = connect(port)

      body = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/call",
        "params" => %{
          "name" => "inspect_context",
          "arguments" => %{"progress" => true},
          "_meta" => %{"progressToken" => "legacy-progress"}
        }
      }

      send_rpc(socket, body,
        legacy: true,
        auth: :alpha,
        headers: [{"mcp-protocol-version", @legacy_version}]
      )

      assert [first, second, result] = socket |> read_all() |> sse_messages()
      assert first["method"] == "notifications/progress"

      assert first["params"] == %{
               "progressToken" => "legacy-progress",
               "progress" => 1,
               "total" => 2,
               "message" => "first"
             }

      assert second["params"]["progress"] == 2
      assert result["result"]["structuredContent"]["principal"] == "alpha"
      refute Map.has_key?(result["result"], "resultType")
    end

    test "#{version} cancellation cannot cross authenticated principals in a mixed runtime" do
      %{port: port} =
        server(
          capabilities: %{"tools" => %{}},
          protocols: [
            Snodo.Protocol.V2026_07_28,
            Snodo.Protocol.V2025_11_25,
            Snodo.Protocol.V2025_06_18
          ]
        )

      options = [legacy: true, headers: [{"mcp-protocol-version", @legacy_version}]]

      body = %{
        "jsonrpc" => "2.0",
        "id" => 77,
        "method" => "tools/call",
        "params" => %{
          "name" => "inspect_context",
          "arguments" => %{"wait" => true}
        }
      }

      socket = connect(port)
      send_rpc(socket, body, Keyword.put(options, :auth, :alpha))
      assert_receive {:tool_entered, 77, worker, token}, 1_000
      monitor = Process.monitor(worker)

      cancellation = %{
        "jsonrpc" => "2.0",
        "method" => "notifications/cancelled",
        "params" => %{"requestId" => 77}
      }

      assert {202, nil} = rpc(port, cancellation, Keyword.put(options, :auth, :beta))
      refute Snodo.Cancellation.cancelled?(token)
      assert {202, nil} = rpc(port, cancellation, Keyword.put(options, :auth, :alpha))
      assert_receive {:DOWN, ^monitor, :process, ^worker, _}, 1_000
      assert Snodo.Cancellation.cancelled?(token)
      assert read_all(socket) =~ "HTTP/1.1 204"
    end
  end

  defp server(opts \\ []) do
    hub_options =
      case Keyword.get(opts, :hub_instrumentation) do
        nil -> []
        instrumentation -> [instrumentation: instrumentation]
      end

    hub = start_supervised!({Hub, hub_options})
    executor_name = Keyword.get(opts, :executor_name)
    executor_opts = Keyword.take(opts, [:max_concurrency, :max_queue])

    executor_opts =
      if executor_name, do: Keyword.put(executor_opts, :name, executor_name), else: executor_opts

    executor = start_supervised!({Executor, executor_opts})
    runtime_opts = [:protocols, :capabilities, :tools, :authorization]

    transport_opts =
      Keyword.drop(
        opts,
        [:max_concurrency, :max_queue, :executor_name, :hub_instrumentation] ++ runtime_opts
      )

    runtime = PlugFixtures.runtime(hub, Keyword.take(opts, runtime_opts))

    plug_opts =
      [runtime: runtime, executor: executor_name || executor, observer: self()] ++ transport_opts

    listener =
      start_supervised!(
        {Bandit,
         plug: {PlugFixtures.Endpoint, plug_opts}, ip: {127, 0, 0, 1}, port: 0, startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(listener)
    %{port: port, hub: hub, executor: executor}
  end

  defp request(method, params, id \\ 1) do
    metadata = %{@version_key => @protocol, @capabilities_key => %{}}

    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => method,
      "params" => Map.put(params, "_meta", metadata)
    }
  end

  defp cancellation(id),
    do: request("notifications/cancelled", %{"requestId" => id}) |> Map.delete("id")

  defp subscription(id),
    do: request("subscriptions/listen", %{"notifications" => %{"toolsListChanged" => true}}, id)

  defp open_stream(port, id) do
    socket = connect(port)
    send_rpc(socket, subscription(id))
    _ack = read_until(socket, "notifications/subscriptions/acknowledged")
    socket
  end

  # With no request running, the executor monitors only the stream processes
  # that hold subscription slots.
  defp slot_holders(executor) do
    {:monitors, monitors} = Process.info(executor, :monitors)
    for {:process, pid} <- monitors, do: pid
  end

  # A subscription worker links the puller that calls the source as it starts.
  defp puller(worker, deadline \\ System.monotonic_time(:millisecond) + 1_000) do
    case Process.info(worker, :links) do
      {:links, [puller]} ->
        puller

      {:links, []} ->
        assert System.monotonic_time(:millisecond) < deadline
        Process.sleep(5)
        puller(worker, deadline)
    end
  end

  # A monitor request can be overtaken by a kill sent from another process.
  # Process.info/2 is a signal from this process too, so it returns only after
  # the target has handled the monitor request sent before it.
  defp monitor_confirmed(pids) do
    for pid <- pids do
      monitor = Process.monitor(pid)
      assert self() in monitored_by(pid)
      {pid, monitor}
    end
  end

  defp await_monitor(pid, watcher) do
    assert eventually(fn -> watcher in monitored_by(pid) end)
    :ok
  end

  defp monitored_by(pid) do
    {:monitored_by, watchers} = Process.info(pid, :monitored_by)
    watchers
  end

  defp large_binaries(pid) do
    true = :erlang.garbage_collect(pid)
    {:binary, binaries} = Process.info(pid, :binary)
    for {_id, size, _references} <- binaries, size >= 1_000_000, do: size
  end

  defp progressing_request(id, arguments) do
    request("tools/call", %{"name" => "inspect_context", "arguments" => arguments}, id)
    |> put_in(["params", "_meta", "progressToken"], "progress-#{id}")
  end

  defp sse_messages(raw) do
    Regex.scan(~r/data: ([^\r\n]+)\r\n\r\n/, raw, capture: :all_but_first)
    |> Enum.map(fn [json] -> JSON.decode!(json) end)
  end

  defp rpc(port, body, opts \\ []) do
    socket = connect(port)
    send_rpc(socket, body, opts)
    raw = read_all(socket)
    [headers, body] = String.split(raw, "\r\n\r\n", parts: 2)
    [_, code | _rest] = String.split(headers, " ")
    {String.to_integer(code), if(body == "", do: nil, else: JSON.decode!(body))}
  end

  defp connect(port) do
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 1_000)
    socket
  end

  defp send_rpc(socket, body, opts \\ []) do
    {head, encoded} = http_request(body, opts)
    :ok = :gen_tcp.send(socket, [head, encoded])
  end

  # The request head, through the blank line, and the encoded body.
  defp http_request(body, opts \\ []) do
    encoded = JSON.encode!(body)

    headers = [
      {"host", "localhost"},
      {"connection", "close"},
      {"content-type", "application/json"},
      {"accept", "application/json, text/event-stream"},
      {"mcp-protocol-version", @protocol},
      {"mcp-method", body["method"]},
      {"content-length", to_string(byte_size(encoded))}
    ]

    headers =
      if opts[:keep_alive], do: List.keydelete(headers, "connection", 0), else: headers

    headers =
      if opts[:legacy],
        do:
          Enum.reject(headers, fn {key, _} -> key in ["mcp-protocol-version", "mcp-method"] end),
        else: headers

    name = if opts[:legacy], do: nil, else: get_in(body, ["params", "name"])
    headers = if name, do: headers ++ [{"mcp-name", name}], else: headers

    headers =
      case Keyword.get(opts, :auth) do
        nil -> headers
        principal -> headers ++ [{"authorization", "Bearer fixture-#{principal}"}]
      end

    headers =
      Enum.reduce(Keyword.get(opts, :replace_headers, []), headers, fn {key, value}, acc ->
        List.keyreplace(acc, key, 0, {key, value})
      end)

    headers = headers ++ Keyword.get(opts, :headers, [])
    lines = Enum.map(headers, fn {key, value} -> [key, ": ", value, "\r\n"] end)
    method = Keyword.get(opts, :method, "POST")
    path = Keyword.get(opts, :path, "/mcp")
    {IO.iodata_to_binary([method, " ", path, " HTTP/1.1\r\n", lines, "\r\n"]), encoded}
  end

  defp read_all(socket, acc \\ "") do
    case :gen_tcp.recv(socket, 0, 2_000) do
      {:ok, data} -> read_all(socket, acc <> data)
      {:error, :closed} -> acc
      {:error, reason} -> flunk("HTTP read failed: #{inspect(reason)}; received #{inspect(acc)}")
    end
  end

  defp read_until(socket, expected, acc \\ "") do
    if String.contains?(acc, expected) do
      acc
    else
      assert {:ok, data} = :gen_tcp.recv(socket, 0, 2_000)
      read_until(socket, expected, acc <> data)
    end
  end

  # Sends one byte of `body` every `interval` ms until the server answers or
  # closes the connection, and returns what it sent.
  defp trickle(socket, body, interval) do
    case {:gen_tcp.recv(socket, 0, interval), body} do
      {{:ok, data}, _body} ->
        read_all(socket, data)

      {{:error, :closed}, _body} ->
        ""

      {{:error, :timeout}, ""} ->
        read_all(socket)

      {{:error, :timeout}, <<byte, rest::binary>>} ->
        _result = :gen_tcp.send(socket, <<byte>>)
        trickle(socket, rest, interval)
    end
  end

  # A minimal HTTP/2 client with prior knowledge over cleartext, one request on
  # stream 1 per connection. Header blocks use HPACK from hpax, which Bandit
  # depends on.
  defp h2_headers(method, content_length) do
    [
      {":method", "POST"},
      {":scheme", "http"},
      {":authority", "localhost"},
      {":path", "/mcp"},
      {"content-type", "application/json"},
      {"accept", "application/json, text/event-stream"},
      {"mcp-protocol-version", @protocol},
      {"mcp-method", method},
      {"content-length", Integer.to_string(content_length)}
    ]
  end

  defp h2_open(port, headers) do
    socket = connect(port)
    {block, _table} = HPAX.encode(:no_store, headers, HPAX.new(4_096))

    :ok =
      :gen_tcp.send(socket, [
        "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n",
        h2_frame(:settings, [], ""),
        h2_frame(:headers, [:end_headers], block)
      ])

    socket
  end

  defp h2_frame(type, flags, payload) do
    payload = IO.iodata_to_binary(payload)
    {code, stream} = Map.fetch!(%{data: {0, 1}, headers: {1, 1}, settings: {4, 0}}, type)
    bits = Map.take(%{end_stream: 0x1, ack: 0x1, end_headers: 0x4}, flags)
    flags = bits |> Map.values() |> Enum.reduce(0, &Bitwise.bor/2)
    [<<byte_size(payload)::24, code, flags, 0::1, stream::31>>, payload]
  end

  # Reads frames until stream 1 ends and returns its status, headers, and body.
  defp h2_response(socket, table \\ HPAX.new(4_096), headers \\ [], body \\ "") do
    assert {:ok, <<size::24, type, flags, _reserved::1, stream::31>>} =
             :gen_tcp.recv(socket, 9, 2_000)

    {:ok, payload} = if size == 0, do: {:ok, ""}, else: :gen_tcp.recv(socket, size, 2_000)
    end_stream = Bitwise.band(flags, 0x1) == 0x1

    case {type, stream} do
      {1, 1} ->
        {:ok, decoded, table} = HPAX.decode(payload, table)
        h2_continue(socket, table, headers ++ decoded, body, end_stream)

      {0, 1} ->
        h2_continue(socket, table, headers, body <> payload, end_stream)

      {4, 0} when not end_stream ->
        :ok = :gen_tcp.send(socket, h2_frame(:settings, [:ack], ""))
        h2_response(socket, table, headers, body)

      _other ->
        h2_response(socket, table, headers, body)
    end
  end

  defp h2_continue(_socket, _table, headers, body, true) do
    {{":status", status}, headers} = List.keytake(headers, ":status", 0)
    {status, headers, body}
  end

  defp h2_continue(socket, table, headers, body, false),
    do: h2_response(socket, table, headers, body)

  defp eventually(check, tries \\ 100)
  defp eventually(_check, 0), do: false

  defp eventually(check, tries) do
    if check.(),
      do: true,
      else:
        (
          Process.sleep(10)
          eventually(check, tries - 1)
        )
  end
end
