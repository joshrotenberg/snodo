defmodule MCP.ClientHTTPTest do
  use ExUnit.Case, async: true

  alias MCP.Client
  alias MCP.Client.HTTP
  alias MCP.Error
  alias MCP.Transport.StreamableHTTP.Server, as: HTTPServer
  alias MCPEx.MRTR.Server, as: ChoiceServer
  alias MCPEx.TestFixtures
  alias MCPEx.TestPrompts.PackageAnalysis
  alias MCPEx.TestResources.StaticText

  defmodule Staged do
    use MCP.Tool, name: "staged"

    @impl true
    def call(_arguments, context) do
      for stage <- 1..3, do: :ok = MCP.Progress.report(context, stage, total: 3)
      {:ok, MCP.Result.text("staged")}
    end
  end

  defmodule FakeHTTP do
    @moduledoc false
    # Answers each request with `respond.(headers, message)` and forwards what
    # it received to `owner`, so tests can assert on the exact wire request.

    def start(owner, respond) do
      {:ok, listen} =
        :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

      {:ok, port} = :inet.port(listen)
      pid = spawn_link(fn -> accept(listen, owner, respond) end)
      :ok = :gen_tcp.controlling_process(listen, pid)
      "http://127.0.0.1:#{port}/mcp"
    end

    defp accept(listen, owner, respond) do
      {:ok, socket} = :gen_tcp.accept(listen)
      :ok = :inet.setopts(socket, packet: :http_bin)
      headers = read_headers(socket, %{})
      :ok = :inet.setopts(socket, packet: :raw)
      {:ok, body} = :gen_tcp.recv(socket, String.to_integer(headers["content-length"]))
      message = JSON.decode!(body)
      send(owner, {:fake_http, headers, message})
      {status, response_headers, response_body} = respond.(headers, message)

      header_lines =
        Enum.map(
          [{"content-length", Integer.to_string(byte_size(response_body))} | response_headers],
          fn {name, value} -> [name, ": ", value, "\r\n"] end
        )

      :ok =
        :gen_tcp.send(socket, [
          "HTTP/1.1 #{status} Fake\r\n",
          header_lines,
          "connection: close\r\n\r\n",
          response_body
        ])

      :ok = :gen_tcp.close(socket)
      accept(listen, owner, respond)
    end

    defp read_headers(socket, headers) do
      case :gen_tcp.recv(socket, 0, 5_000) do
        {:ok, {:http_request, _method, _uri, _version}} ->
          read_headers(socket, headers)

        {:ok, {:http_header, _field, name, _reserved, value}} ->
          read_headers(socket, Map.put(headers, String.downcase(to_string(name)), value))

        {:ok, :http_eoh} ->
          headers
      end
    end
  end

  defp serve(runtime) do
    server = start_supervised!({HTTPServer, runtime: runtime, port: 0})
    HTTPServer.url(server)
  end

  defp connect(url, opts \\ []) do
    {:ok, client} = Client.connect({:http, url}, opts)
    client
  end

  defp json(message, result) do
    body = JSON.encode!(%{"jsonrpc" => "2.0", "id" => message["id"], "result" => result})
    {200, [{"content-type", "application/json"}], body}
  end

  describe "against the native listener" do
    test "discovers, lists, reads, gets, and calls" do
      url =
        serve(
          TestFixtures.runtime(
            resources: [StaticText],
            prompts: [PackageAnalysis],
            pagination: [page_size: 2]
          )
        )

      client = connect(url)

      assert {:ok, %{"supportedVersions" => ["2026-07-28"]}} = Client.discover(client)
      assert {:ok, tools} = Client.list_tools(client)
      assert length(tools) == 6

      assert {:ok, %{"content" => [%{"text" => "over HTTP"}]}} =
               Client.call_tool(client, "echo", %{"text" => "over HTTP"})

      assert {:ok, %{"contents" => [%{"uri" => "test://static/readme"}]}} =
               Client.read_resource(client, "test://static/readme")

      assert {:ok, %{"messages" => [_message | _rest]}} =
               Client.get_prompt(client, "package_analysis", %{"name" => "plug"})

      assert {:ok, %{"isError" => true}} = Client.call_tool(client, "failing")
    end

    test "a JSON-RPC error on an HTTP 400 decodes as MCP.Error" do
      client = connect(serve(TestFixtures.runtime(resources: [StaticText])))

      assert {:error, %Error{code: -32_602, kind: :protocol}} =
               Client.call_tool(client, "no_such_tool")

      assert {:error, %Error{code: -32_602}} = Client.read_resource(client, "test://missing")
    end

    test "returns the final response when progress switches the reply to an event stream" do
      client = connect(serve(TestFixtures.runtime(tools: [Staged])))

      assert {:ok, %{"content" => [%{"text" => "staged"}]}} =
               Client.call_tool(client, "staged", %{}, meta: %{"progressToken" => "stages"})
    end

    test "input_required results retry over HTTP" do
      client =
        connect(serve(ChoiceServer.runtime()),
          client_capabilities: %{"elicitation" => %{"form" => %{}}}
        )

      assert {:input_required, %{"inputRequests" => %{"choice" => _request}}} =
               Client.call_tool(client, "choice")

      answer = %{"action" => "accept", "content" => %{"label" => "http"}}

      assert {:ok, %{"structuredContent" => %{"label" => "http"}}} =
               Client.call_tool(client, "choice", %{}, input_responses: %{"choice" => answer})
    end

    test "a timeout returns -32001 and the listener keeps serving" do
      client = connect(serve(TestFixtures.runtime()))

      assert {:error, %Error{code: -32_001, kind: :transport}} =
               Client.call_tool(client, "echo", %{"text" => "slow", "delayMs" => 2_000},
                 timeout: 100
               )

      assert {:ok, _result} = Client.call_tool(client, "echo", %{"text" => "fast"})
    end
  end

  describe "request headers and responses" do
    test "sends the dialect's mirrored headers, extra headers, and a base64 Mcp-Name" do
      url = FakeHTTP.start(self(), fn _headers, message -> json(message, %{"contents" => []}) end)
      client = connect(url, headers: [{"authorization", "Bearer token"}])

      assert {:ok, %{"contents" => []}} = Client.read_resource(client, "test://café")

      assert_receive {:fake_http, headers, %{"method" => "resources/read"}}
      assert headers["mcp-protocol-version"] == "2026-07-28"
      assert headers["mcp-method"] == "resources/read"
      assert headers["mcp-name"] == "=?base64?" <> Base.encode64("test://café") <> "?="
      assert headers["content-type"] == "application/json"
      assert headers["accept"] == "application/json, text/event-stream"
      assert headers["authorization"] == "Bearer token"

      assert {:ok, _result} = Client.call_tool(client, "plain_name")
      assert_receive {:fake_http, %{"mcp-name" => "plain_name"}, _message}
    end

    test "takes the matching response from an event stream and skips notifications" do
      url =
        FakeHTTP.start(self(), fn _headers, message ->
          progress = %{
            "jsonrpc" => "2.0",
            "method" => "notifications/progress",
            "params" => %{"progressToken" => "t", "progress" => 1}
          }

          response = %{
            "jsonrpc" => "2.0",
            "id" => message["id"],
            "result" => %{"content" => [], "isError" => false}
          }

          body =
            "event: message\ndata: #{JSON.encode!(progress)}\n\n" <>
              "data: #{JSON.encode!(response)}\r\n\r\n"

          {200, [{"content-type", "text/event-stream"}], body}
        end)

      assert {:ok, %{"isError" => false}} = Client.call_tool(connect(url), "echo")
    end

    test "a response that is not JSON-RPC is a transport error carrying the status" do
      url = FakeHTTP.start(self(), fn _headers, _message -> {502, [], "Bad Gateway"} end)

      assert {:error, %Error{code: -32_000, kind: :transport, cause: cause}} =
               Client.discover(connect(url))

      assert cause == {:http_status, 502, "Bad Gateway"}
    end

    test "list functions stop when a server repeats a cursor" do
      url =
        FakeHTTP.start(self(), fn _headers, message ->
          json(message, %{"tools" => [%{"name" => "loop"}], "nextCursor" => "again"})
        end)

      assert {:error, %Error{code: -32_000, cause: %{kind: :tools, cursor: "again"}}} =
               Client.list_tools(connect(url))
    end
  end

  describe "connection failures" do
    test "an unreachable endpoint is a -32000 transport error" do
      {:ok, listen} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
      {:ok, port} = :inet.port(listen)
      :ok = :gen_tcp.close(listen)

      client = connect("http://127.0.0.1:#{port}/mcp")

      assert {:error, %Error{code: -32_000, kind: :transport, cause: {:failed_connect, _}}} =
               Client.discover(client)
    end

    test "a URL that is not http or https is refused at connect" do
      assert {:error, %Error{code: -32_000, kind: :transport}} =
               Client.connect({:http, "ftp://example.test/mcp"})

      assert {:error, %Error{code: -32_000}} = Client.connect({:http, "not a url"})
    end

    test "a protocol the client does not implement is refused at connect" do
      assert {:error, %Error{code: -32_602, data: %{"supported" => ["2026-07-28"]}}} =
               Client.connect({:http, "http://127.0.0.1:1/mcp"}, protocol: "2025-11-25")
    end
  end

  test "encode_sentinel/1 leaves printable ASCII alone and encodes everything else" do
    assert HTTP.encode_sentinel("echo") == "echo"
    assert HTTP.encode_sentinel("test://static/readme") == "test://static/readme"

    for value <- ["café", " padded", "line\nbreak", "=?base64?Zm9v?="] do
      assert HTTP.encode_sentinel(value) == "=?base64?" <> Base.encode64(value) <> "?="
    end
  end
end
