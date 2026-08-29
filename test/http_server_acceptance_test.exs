defmodule MCP.Transport.StreamableHTTP.ServerAcceptanceTest do
  use ExUnit.Case, async: true

  alias MCP.Server.Executor
  alias MCP.Subscription.Event
  alias MCP.Transport.StreamableHTTP.Server, as: HTTPServer
  alias MCPEx.TestFixtures
  alias MCPEx.TestResources.StaticText
  alias MCPEx.TestSubscriptionHub
  alias MCPEx.TestSubscriptionSource
  alias MCPEx.TestTools.Echo
  alias MCPEx.TestTools.Trapping

  @protocol "2026-07-28"

  @tag mcp_contract: ["streamable-http-listener"]
  test "binds to localhost, serves the configured path, and closes each response" do
    runtime = TestFixtures.runtime()
    {:ok, server} = start_supervised({HTTPServer, runtime: runtime, port: 0})
    {{127, 0, 0, 1}, port, "/mcp"} = HTTPServer.address(server)
    assert HTTPServer.url(server) == "http://127.0.0.1:#{port}/mcp"

    raw = TestFixtures.request("http-list", "tools/list")
    response = raw_request(port, "POST", "/mcp", headers(raw), JSON.encode!(raw))

    assert response.status == 200
    assert response.headers["connection"] == "close"
    assert response.headers["content-type"] == "application/json"

    assert %{"id" => "http-list", "result" => %{"tools" => tools}} =
             JSON.decode!(response.body)

    assert Enum.any?(tools, &(&1["name"] == "echo"))

    wrong_path = raw_request(port, "POST", "/elsewhere", headers(raw), JSON.encode!(raw))
    assert wrong_path.status == 404

    get_response = raw_request(port, "GET", "/mcp", [], "")
    assert get_response.status == 405
    assert get_response.headers["allow"] == "POST"
  end

  test "serves resource reads through the live listener with exact URI headers" do
    runtime = TestFixtures.runtime(resources: [StaticText])
    {:ok, server} = start_supervised({HTTPServer, runtime: runtime, port: 0})
    {_ip, port, _path} = HTTPServer.address(server)

    raw =
      TestFixtures.request("live-resource", "resources/read", %{
        "uri" => "test://static/readme"
      })

    response = post(port, raw)
    assert response.status == 200

    assert get_in(JSON.decode!(response.body), ["result", "contents", Access.at(0), "text"]) ==
             "# Static resource\n"
  end

  test "independent HTTP requests share bounded concurrent execution" do
    runtime = TestFixtures.runtime(tools: [Echo])

    {:ok, server} =
      start_supervised({HTTPServer, runtime: runtime, port: 0, max_concurrency: 2})

    {_ip, port, _path} = HTTPServer.address(server)

    slow =
      TestFixtures.request("slow-http", "tools/call", %{
        "name" => "echo",
        "arguments" => %{"text" => "slow", "delayMs" => 150}
      })

    fast =
      TestFixtures.request("fast-http", "tools/call", %{
        "name" => "echo",
        "arguments" => %{"text" => "fast"}
      })

    parent = self()

    slow_task =
      Task.async(fn ->
        result = post(port, slow)
        send(parent, {:completed, "slow-http"})
        result
      end)

    Process.sleep(20)

    fast_task =
      Task.async(fn ->
        result = post(port, fast)
        send(parent, {:completed, "fast-http"})
        result
      end)

    assert_receive {:completed, "fast-http"}, 1_000
    assert_receive {:completed, "slow-http"}, 1_000
    assert Task.await(fast_task).status == 200
    assert Task.await(slow_task).status == 200
  end

  test "peer disconnect cancels only its executor work and injected executor stays owned" do
    runtime = TestFixtures.runtime(tools: [Echo, Trapping])
    {:ok, executor} = start_supervised({Executor, default_timeout: :infinity})
    token = Integer.to_string(System.unique_integer([:positive]))
    :yes = :global.register_name({Trapping, token}, self())

    on_exit(fn -> :global.unregister_name({Trapping, token}) end)

    {:ok, server} =
      start_supervised({HTTPServer, runtime: runtime, port: 0, executor: executor})

    {_ip, port, _path} = HTTPServer.address(server)

    raw =
      TestFixtures.request("disconnect-http", "tools/call", %{
        "name" => "trapping",
        "arguments" => %{"token" => token}
      })

    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])
    :ok = :gen_tcp.send(socket, encoded_request("POST", "/mcp", headers(raw), JSON.encode!(raw)))
    assert_receive {:trapping_entered, _worker, cancellation}, 1_000
    refute MCP.Cancellation.cancelled?(cancellation)

    :ok = :gen_tcp.close(socket)
    assert eventually(fn -> MCP.Cancellation.cancelled?(cancellation) end)
    assert eventually(fn -> Executor.stats(executor).running == 0 end)
    assert Process.alive?(executor)

    response =
      post(
        port,
        TestFixtures.request("after-disconnect", "tools/call", %{
          "name" => "echo",
          "arguments" => %{"text" => "still alive"}
        })
      )

    assert response.status == 200
  end

  test "origin validation rejects the frozen DNS rebinding probe and accepts localhost" do
    runtime = TestFixtures.runtime()
    {:ok, server} = start_supervised({HTTPServer, runtime: runtime, port: 0})
    {_ip, port, _path} = HTTPServer.address(server)
    raw = TestFixtures.request("origin-http", "server/discover")

    invalid_headers =
      [{"Host", "evil.example.com"}, {"Origin", "http://evil.example.com"} | headers(raw)]

    assert raw_request(port, "POST", "/mcp", invalid_headers, JSON.encode!(raw)).status == 403

    valid_headers =
      [
        {"Host", "127.0.0.1:#{port}"},
        {"Origin", "http://127.0.0.1:#{port}"}
        | headers(raw)
      ]

    assert raw_request(port, "POST", "/mcp", valid_headers, JSON.encode!(raw)).status == 200
  end

  @tag mcp_contract: ["subscriptions-http-sse", "subscriptions-disconnect"]
  test "streams acknowledgement, events, and completion over SSE and cleans up disconnects" do
    {:ok, hub} = start_supervised({TestSubscriptionHub, owner: self()})

    runtime =
      TestFixtures.runtime(
        capabilities: %{"tools" => %{"listChanged" => true}},
        subscription_source: {TestSubscriptionSource, hub}
      )

    {:ok, server} = start_supervised({HTTPServer, runtime: runtime, port: 0})
    {_ip, port, _path} = HTTPServer.address(server)

    raw =
      TestFixtures.request("http-sub", "subscriptions/listen", %{
        "notifications" => %{"toolsListChanged" => true}
      })

    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])
    :ok = :gen_tcp.send(socket, encoded_request("POST", "/mcp", headers(raw), JSON.encode!(raw)))

    assert_receive {:subscription_opened, "http-sub", %{"toolsListChanged" => true}}, 1_000
    assert_receive {:subscription_next, "http-sub"}, 1_000

    acknowledgement_chunk =
      recv_until(socket, "notifications/subscriptions/acknowledged")

    assert acknowledgement_chunk =~ "HTTP/1.1 200 OK"
    assert acknowledgement_chunk =~ "Content-Type: text/event-stream"
    assert acknowledgement_chunk =~ "X-Accel-Buffering: no"
    refute acknowledgement_chunk =~ "Content-Length:"

    assert :ok = TestSubscriptionHub.emit(hub, "http-sub", Event.tools_list_changed())
    event_chunk = recv_until(socket, "notifications/tools/list_changed")
    assert_receive {:subscription_next, "http-sub"}, 1_000

    assert :ok = TestSubscriptionHub.complete(hub, "http-sub")
    terminal_chunk = recv_all(socket, "")
    full_response = acknowledgement_chunk <> event_chunk <> terminal_chunk
    messages = sse_messages(full_response)

    assert Enum.map(messages, & &1["method"]) == [
             "notifications/subscriptions/acknowledged",
             "notifications/tools/list_changed",
             nil
           ]

    assert List.last(messages)["id"] == "http-sub"
    assert get_in(List.last(messages), ["result", "resultType"]) == "complete"
    assert_receive {:subscription_closed, "http-sub", :complete}, 1_000

    disconnected =
      TestFixtures.request("http-disconnect", "subscriptions/listen", %{
        "notifications" => %{"toolsListChanged" => true}
      })

    {:ok, disconnected_socket} =
      :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])

    :ok =
      :gen_tcp.send(
        disconnected_socket,
        encoded_request("POST", "/mcp", headers(disconnected), JSON.encode!(disconnected))
      )

    assert_receive {:subscription_opened, "http-disconnect", _filter}, 1_000

    _acknowledgement =
      recv_until(disconnected_socket, "notifications/subscriptions/acknowledged")

    :ok = :gen_tcp.close(disconnected_socket)
    assert_receive {:subscription_closed, "http-disconnect", :disconnected}, 1_000
  end

  defp post(port, raw) do
    raw_request(port, "POST", "/mcp", headers(raw), JSON.encode!(raw))
  end

  defp raw_request(port, method, path, request_headers, body) do
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])
    :ok = :gen_tcp.send(socket, encoded_request(method, path, request_headers, body))
    response = recv_all(socket, "")
    parse_response(response)
  end

  defp encoded_request(method, path, request_headers, body) do
    headers =
      request_headers
      |> delete_header("content-length")
      |> then(&[{"Content-Length", Integer.to_string(byte_size(body))} | &1])

    header_lines = Enum.map(headers, fn {name, value} -> [name, ": ", value, "\r\n"] end)
    [method, " ", path, " HTTP/1.1\r\n", header_lines, "\r\n", body]
  end

  defp recv_all(socket, acc) do
    case :gen_tcp.recv(socket, 0, 2_000) do
      {:ok, chunk} -> recv_all(socket, acc <> chunk)
      {:error, :closed} -> acc
    end
  end

  defp recv_until(socket, pattern, acc \\ "") do
    if String.contains?(acc, pattern) do
      acc
    else
      case :gen_tcp.recv(socket, 0, 2_000) do
        {:ok, chunk} -> recv_until(socket, pattern, acc <> chunk)
        {:error, reason} -> flunk("socket closed before #{inspect(pattern)}: #{inspect(reason)}")
      end
    end
  end

  defp sse_messages(response) do
    [_head, body] = :binary.split(response, "\r\n\r\n")

    body
    |> String.split("\r\n\r\n", trim: true)
    |> Enum.flat_map(fn frame ->
      case String.split(frame, "data: ", parts: 2) do
        [_prefix, json] -> [JSON.decode!(json)]
        _comment_or_empty -> []
      end
    end)
  end

  defp parse_response(response) do
    [head, body] = :binary.split(response, "\r\n\r\n")
    [status_line | header_lines] = :binary.split(head, "\r\n", [:global])
    ["HTTP/1.1", status | _reason] = String.split(status_line, " ")

    headers =
      Map.new(header_lines, fn line ->
        [name, value] = :binary.split(line, ":")
        {String.downcase(name), String.trim(value)}
      end)

    %{status: String.to_integer(status), headers: headers, body: body}
  end

  defp headers(raw) do
    method = raw["method"]

    [
      {"Content-Type", "application/json"},
      {"Accept", "application/json, text/event-stream"},
      {"MCP-Protocol-Version", @protocol},
      {"Mcp-Method", method}
    ] ++
      case method do
        "tools/call" -> [{"Mcp-Name", get_in(raw, ["params", "name"])}]
        "resources/read" -> [{"Mcp-Name", get_in(raw, ["params", "uri"])}]
        _other -> []
      end
  end

  defp delete_header(headers, name) do
    wanted = String.downcase(name)
    Enum.reject(headers, fn {key, _value} -> String.downcase(key) == wanted end)
  end

  defp eventually(fun, attempts \\ 100)

  defp eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  defp eventually(_fun, 0), do: false
end
