defmodule Snodo.ClientHTTPTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Snodo.Client
  alias Snodo.Client.HTTP
  alias Snodo.Client.Subscription
  alias Snodo.Error
  alias Snodo.Subscription.Event
  alias Snodo.Transport.StreamableHTTP.Server, as: HTTPServer
  alias SnodoTest.MRTR.Server, as: ChoiceServer
  alias SnodoTest.TestFixtures
  alias SnodoTest.TestPrompts.PackageAnalysis
  alias SnodoTest.TestResources.StaticText
  alias SnodoTest.TestSubscriptionHub
  alias SnodoTest.TestSubscriptionSource
  alias SnodoTest.TestTools.Routed
  alias SnodoTest.TestTools.Ticks

  defmodule Staged do
    use Snodo.Tool, name: "staged"

    @impl true
    def call(_arguments, context) do
      for stage <- 1..3, do: :ok = Snodo.Progress.report(context, stage, total: 3)
      {:ok, Snodo.Result.text("staged")}
    end
  end

  defmodule FakeHTTP do
    @moduledoc false
    # Answers each request with `respond.(headers, message)` and forwards what
    # it received to `owner`, so tests can assert on the exact wire request.
    #
    # `respond` returns `{status, headers, body}`, sent with a Content-Length;
    # `{status, headers, {:stream, chunks}}`, sent without one until a send
    # fails, after which the bytes sent go to `owner` as `{:fake_http_sent, n}`;
    # or `{:raw, iodata}`, sent as it is.

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
      # A client that stops reading without closing fails the send in 5 s.
      :ok = :inet.setopts(socket, packet: :http_bin, send_timeout: 5_000)
      headers = read_headers(socket, %{})
      :ok = :inet.setopts(socket, packet: :raw)
      {:ok, body} = :gen_tcp.recv(socket, String.to_integer(headers["content-length"]))
      message = JSON.decode!(body)
      send(owner, {:fake_http, headers, message})
      _result = reply(socket, owner, respond.(headers, message))
      :ok = :gen_tcp.close(socket)
      accept(listen, owner, respond)
    end

    defp reply(socket, _owner, {:raw, data}), do: :gen_tcp.send(socket, data)

    defp reply(socket, owner, {status, headers, {:stream, chunks}}) do
      _result = :gen_tcp.send(socket, head(status, headers))

      sent =
        Enum.reduce_while(chunks, 0, fn chunk, sent ->
          case :gen_tcp.send(socket, chunk) do
            :ok -> {:cont, sent + byte_size(chunk)}
            {:error, _closed} -> {:halt, sent}
          end
        end)

      send(owner, {:fake_http_sent, sent})
    end

    defp reply(socket, _owner, {status, headers, body}) do
      length = {"content-length", Integer.to_string(byte_size(body))}
      :gen_tcp.send(socket, [head(status, [length | headers]), body])
    end

    defp head(status, headers) do
      [
        "HTTP/1.1 #{status} Fake\r\n",
        Enum.map(headers, fn {name, value} -> [name, ": ", value, "\r\n"] end),
        "connection: close\r\n\r\n"
      ]
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

  @mib 1_048_576
  @json_type {"content-type", "application/json"}

  # 256 MiB in 64 KiB chunks, produced as they are sent.
  defp large_body(chunk \\ :binary.copy("x", 65_536)) do
    Stream.duplicate(chunk, div(256 * @mib, byte_size(chunk)))
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

    test "a JSON-RPC error on an HTTP 400 decodes as Snodo.Error" do
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

    test "delivers progress from the event stream in order before the result" do
      client = connect(serve(TestFixtures.runtime(tools: [Ticks])))

      assert {:ok, %{"content" => [%{"text" => "ticked 3"}]}} =
               Client.call_tool(client, "ticks", %{"count" => 3}, progress: self())

      assert [
               %{"progress" => 1, "total" => 3, "message" => "tick 1"},
               %{"progress" => 2},
               %{"progress" => 3}
             ] = drain_progress()
    end

    test "reset_timeout_on_progress keeps a request alive up to max_total_timeout" do
      client = connect(serve(TestFixtures.runtime(tools: [Ticks])))
      arguments = %{"count" => 10, "intervalMs" => 100}

      assert {:error, %Error{code: -32_001, data: %{"timeoutMs" => 500}}} =
               Client.call_tool(client, "ticks", arguments, progress: self(), timeout: 500)

      assert {:ok, %{"content" => [%{"text" => "ticked 10"}]}} =
               Client.call_tool(client, "ticks", arguments,
                 progress: self(),
                 timeout: 500,
                 reset_timeout_on_progress: true
               )

      assert {:error,
              %Error{
                code: -32_001,
                message: "Maximum total timeout exceeded",
                data: %{"maxTotalTimeoutMs" => 700}
              }} =
               Client.call_tool(client, "ticks", arguments,
                 progress: self(),
                 timeout: 500,
                 reset_timeout_on_progress: true,
                 max_total_timeout: 700
               )
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

    test "input handlers answer form and URL requests over HTTP" do
      handlers = %{
        form: fn %{"mode" => "form"} ->
          {:ok, %{"action" => "accept", "content" => %{"label" => "http"}}}
        end,
        url: fn %{"mode" => "url"} -> {:ok, %{"action" => "accept"}} end
      }

      client = connect(serve(ChoiceServer.runtime()), input_handlers: handlers)

      assert {:ok, %{"structuredContent" => %{"label" => "http"}}} =
               Client.call_tool(client, "choice")

      assert {:ok, %{"structuredContent" => %{"action" => "accept"}}} =
               Client.call_tool(client, "consent")

      assert {:ok, %{"structuredContent" => %{"first" => "http", "second" => "http"}}} =
               Client.call_tool(client, "sequential_choices")

      assert {:input_required, %{"inputRequests" => %{"choice" => _request}}} =
               Client.call_tool(client, "choice", %{}, answer_input: false)
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

  describe "x-mcp-header parameters" do
    test "a call with the tool definition sends the headers the native listener checks" do
      client = connect(serve(TestFixtures.runtime(tools: [Routed])))
      assert {:ok, [routed]} = Client.list_tools(client)
      arguments = %{"region" => " padded ", "priority" => 7, "target" => %{"zone" => "b"}}

      assert {:ok, %{"structuredContent" => ^arguments}} =
               Client.call_tool(client, routed, arguments)
    end

    test "a call by name is refused once, then retried with the listed definition" do
      client = connect(serve(TestFixtures.runtime(tools: [Routed])))

      assert {:ok, %{"structuredContent" => %{"region" => "us-west1"}}} =
               Client.call_tool(client, "routed", %{"region" => "us-west1"})
    end

    test "encodes each argument type and omits null arguments" do
      url = FakeHTTP.start(self(), fn _headers, message -> json(message, %{"content" => []}) end)
      client = connect(url)

      properties =
        for {name, type} <- [
              {"plain", "string"},
              {"empty", "string"},
              {"unsafe", "string"},
              {"count", "integer"},
              {"flag", "boolean"},
              {"missing", "string"}
            ],
            into: %{},
            do: {name, %{"type" => type, "x-mcp-header" => String.capitalize(name)}}

      tool = %{
        "name" => "encoded",
        "inputSchema" => %{"type" => "object", "properties" => properties}
      }

      arguments = %{
        "plain" => "us west 1",
        "empty" => "",
        "unsafe" => "line1\nline2",
        "count" => 42,
        "flag" => true,
        "missing" => nil
      }

      assert {:ok, _result} = Client.call_tool(client, tool, arguments)
      assert_receive {:fake_http, headers, %{"method" => "tools/call"}}

      assert headers["mcp-param-plain"] == "us west 1"
      assert headers["mcp-param-empty"] == ""
      assert headers["mcp-param-unsafe"] == "=?base64?" <> Base.encode64("line1\nline2") <> "?="
      assert headers["mcp-param-count"] == "42"
      assert headers["mcp-param-flag"] == "true"
      refute Map.has_key?(headers, "mcp-param-missing")
    end

    test "list_tools leaves out and logs tools with invalid annotations" do
      tools = [
        %{"name" => "valid", "inputSchema" => %{"type" => "object"}},
        %{
          "name" => "invalid",
          "inputSchema" => %{
            "type" => "object",
            "properties" => %{"v" => %{"type" => "object", "x-mcp-header" => "V"}}
          }
        }
      ]

      url = FakeHTTP.start(self(), fn _headers, message -> json(message, %{"tools" => tools}) end)
      client = connect(url)

      {result, log} = with_log(fn -> Client.list_tools(client) end)
      assert {:ok, [%{"name" => "valid"}]} = result
      assert log =~ ~s(Ignoring tool "invalid")
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

    test "parses events split across reads and returns without waiting for the stream to end" do
      url =
        FakeHTTP.start(self(), fn _headers, message ->
          token = get_in(message, ["params", "_meta", "progressToken"])

          event = fn payload -> "data: " <> JSON.encode!(payload) end

          progress = fn token, value ->
            event.(%{
              "jsonrpc" => "2.0",
              "method" => "notifications/progress",
              "params" => %{"progressToken" => token, "progress" => value}
            })
          end

          response = event.(%{"jsonrpc" => "2.0", "id" => message["id"], "result" => %{}})

          text =
            "event: message\r\n" <>
              progress.(token, 1) <>
              "\r\n\r\n" <>
              progress.("another-request", 9) <>
              "\n\n" <> progress.(token, 2) <> "\n\n" <> response <> "\n\n"

          pieces =
            Stream.unfold(text, fn
              "" -> nil
              rest -> String.split_at(rest, 7)
            end)

          # The stream stays open after the response, as a server's may.
          keepalive = Stream.repeatedly(fn -> ": keepalive\n\n" end)

          paced =
            Stream.map(Stream.concat(pieces, keepalive), fn piece ->
              Process.sleep(1)
              piece
            end)

          {200, [{"content-type", "text/event-stream"}], {:stream, paced}}
        end)

      assert {:ok, %{}} = Client.request(connect(url), "tools/list", %{}, progress: self())
      assert [%{"progress" => 1}, %{"progress" => 2}] = drain_progress()
    end

    test "a response that is not JSON-RPC is a transport error carrying the status" do
      url = FakeHTTP.start(self(), fn _headers, _message -> {502, [], "Bad Gateway"} end)

      assert {:error, %Error{code: -32_000, kind: :transport, cause: cause}} =
               Client.discover(connect(url))

      assert cause == {:http_status, 502, "Bad Gateway"}
    end

    test "a huge integer in a response is a transport error, not a raise" do
      # The standard decoder raises SystemLimitError at about 1.25 million digits.
      huge =
        ~s({"jsonrpc":"2.0","id":1,"result":{"n":) <> String.duplicate("9", 1_500_000) <> "}}"

      url =
        FakeHTTP.start(self(), fn _headers, _message ->
          {200, [{"content-type", "application/json"}], huge}
        end)

      assert {:error, %Error{code: -32_000, kind: :transport}} = Client.discover(connect(url))

      event = "event: message\ndata: " <> huge <> "\n\n"

      url =
        FakeHTTP.start(self(), fn _headers, _message ->
          {200, [{"content-type", "text/event-stream"}], event}
        end)

      assert {:error, %Error{code: -32_000, kind: :transport}} = Client.discover(connect(url))
    end

    test "list functions stop when a server repeats a cursor" do
      url =
        FakeHTTP.start(self(), fn _headers, message ->
          json(message, %{"tools" => [%{"name" => "loop"}], "nextCursor" => "again"})
        end)

      assert {:error, %Error{code: -32_000, cause: %{kind: :tools, cursor: "again"}}} =
               Client.list_tools(connect(url))
    end

    test "list functions stop at :max_pages when a server never stops paging" do
      url =
        FakeHTTP.start(self(), fn _headers, message ->
          cursor = "page-#{message["id"]}"
          json(message, %{"tools" => [%{"name" => cursor}], "nextCursor" => cursor})
        end)

      assert {:error, %Error{code: -32_000, cause: %{kind: :tools, max_pages: 3}}} =
               Client.list_tools(connect(url, max_pages: 3))

      for _page <- 1..3 do
        assert_receive {:fake_http, _headers, %{"method" => "tools/list"}}, 1_000
      end

      refute_received {:fake_http, _headers, _message}
    end

    test "decodes a chunked response that follows an interim 1xx response" do
      url =
        FakeHTTP.start(self(), fn _headers, message ->
          {200, _json_headers, body} = json(message, %{})
          {first, second} = String.split_at(body, 10)
          size = &Integer.to_string(byte_size(&1), 16)

          {:raw,
           [
             "HTTP/1.1 100 Continue\r\n\r\n",
             "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\n",
             "transfer-encoding: chunked\r\n\r\n",
             [size.(first), ";ext=1\r\n", first, "\r\n"],
             [size.(second), "\r\n", second, "\r\n"],
             "0\r\n\r\n"
           ]}
        end)

      assert {:ok, %{}} = Client.discover(connect(url))
    end

    test "a header value with a line break is refused before anything is sent" do
      url = FakeHTTP.start(self(), fn _headers, message -> json(message, %{}) end)

      assert {:error, %Error{code: -32_000, kind: :transport}} =
               Client.request(connect(url), "tools/list\r\nx-injected: 1")

      refute_received {:fake_http, _headers, _message}

      for header <- [{"x-extra", "a\r\nb"}, {"Content-Length", "5"}] do
        assert_raise ArgumentError, ~r/:headers must be/, fn ->
          Client.connect({:http, url}, headers: [header])
        end
      end
    end
  end

  describe ":max_response_bytes" do
    test "a close-delimited body is refused as it arrives, at any status" do
      for status <- [200, 500] do
        url =
          FakeHTTP.start(self(), fn _headers, _message ->
            {status, [@json_type], {:stream, large_body()}}
          end)

        assert {:error, %Error{code: -32_000, kind: :transport, cause: cause}} =
                 Client.discover(connect(url, max_response_bytes: @mib))

        assert cause == {:max_response_bytes, @mib}

        # The client closed the connection long before the server could send
        # the 256 MiB body.
        assert_receive {:fake_http_sent, sent}, 5_000
        assert sent < 32 * @mib
      end
    end

    test "a Content-Length over the limit is refused before the body is read" do
      url =
        FakeHTTP.start(self(), fn _headers, _message ->
          {500, [@json_type, {"content-length", "268435456"}], {:stream, large_body()}}
        end)

      assert {:error, %Error{cause: {:max_response_bytes, @mib}}} =
               Client.discover(connect(url, max_response_bytes: @mib))

      assert_receive {:fake_http_sent, sent}, 5_000
      assert sent < 32 * @mib
    end

    test "a chunked body is refused at the first chunk that passes the limit" do
      chunk = ["10000\r\n", :binary.copy("x", 65_536), "\r\n"] |> IO.iodata_to_binary()

      url =
        FakeHTTP.start(self(), fn _headers, _message ->
          {200, [@json_type, {"transfer-encoding", "chunked"}], {:stream, large_body(chunk)}}
        end)

      assert {:error, %Error{cause: {:max_response_bytes, @mib}}} =
               Client.discover(connect(url, max_response_bytes: @mib))

      assert_receive {:fake_http_sent, sent}, 5_000
      assert sent < 32 * @mib
    end

    test "an event stream counts as one body, notifications included" do
      progress = %{
        "jsonrpc" => "2.0",
        "method" => "notifications/progress",
        "params" => %{"progressToken" => "t", "progress" => 1}
      }

      event = "data: #{JSON.encode!(progress)}\n\n"

      url =
        FakeHTTP.start(self(), fn _headers, _message ->
          chunk = :binary.copy(event, div(65_536, byte_size(event)))
          {200, [{"content-type", "text/event-stream"}], {:stream, large_body(chunk)}}
        end)

      assert {:error, %Error{cause: {:max_response_bytes, @mib}}} =
               Client.call_tool(connect(url, max_response_bytes: @mib), "echo")

      assert_receive {:fake_http_sent, sent}, 5_000
      assert sent < 32 * @mib
    end

    test "a body of exactly the limit is accepted" do
      padding = String.duplicate("x", 1_000)
      body = JSON.encode!(%{"jsonrpc" => "2.0", "id" => 1, "result" => %{"pad" => padding}})
      url = FakeHTTP.start(self(), fn _headers, _message -> {200, [@json_type], body} end)

      assert {:ok, %{"pad" => ^padding}} =
               Client.discover(connect(url, max_response_bytes: byte_size(body)))

      assert {:error, %Error{cause: {:max_response_bytes, _limit}}} =
               Client.discover(connect(url, max_response_bytes: byte_size(body) - 1))
    end

    test "must be a positive integer" do
      assert_raise ArgumentError, ~r/:max_response_bytes/, fn ->
        Client.connect({:http, "http://127.0.0.1:1/mcp"}, max_response_bytes: 0)
      end
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

  describe "subscriptions against the native listener" do
    @tools_filter %{"toolsListChanged" => true}

    setup do
      {:ok, hub} = start_supervised({TestSubscriptionHub, owner: self()})

      runtime =
        TestFixtures.runtime(
          capabilities: %{
            "tools" => %{"listChanged" => true},
            "resources" => %{"subscribe" => true}
          },
          subscription_source: {TestSubscriptionSource, hub}
        )

      %{hub: hub, client: connect(serve(runtime))}
    end

    test "listen/3 returns the accepted filter and delivers events on demand",
         %{hub: hub, client: client} do
      requested = %{
        "toolsListChanged" => true,
        "promptsListChanged" => true,
        "resourceSubscriptions" => ["test://resource/one"]
      }

      assert {:ok, %Subscription{accepted: accepted, id: id, ref: ref} = subscription} =
               Client.listen(client, requested)

      assert accepted == Map.delete(requested, "promptsListChanged")
      assert_receive {:subscription_opened, ^id, ^accepted}, 1_000

      :ok = Subscription.demand(subscription, 2)
      :ok = TestSubscriptionHub.emit(hub, id, Event.resource_updated("test://resource/one"))
      :ok = TestSubscriptionHub.emit(hub, id, tools_changed(1))
      :ok = TestSubscriptionHub.emit(hub, id, tools_changed(2))

      assert_receive {:snodo_subscription, ^ref,
                      {:notification, "notifications/resources/updated", updated}},
                     1_000

      assert updated["uri"] == "test://resource/one"
      assert updated["_meta"]["io.modelcontextprotocol/subscriptionId"] == id

      assert_receive {:snodo_subscription, ^ref,
                      {:notification, "notifications/tools/list_changed", first}},
                     1_000

      assert first["_meta"]["seq"] == 1
      refute_receive {:snodo_subscription, ^ref, _payload}, 100

      assert {:notification, "notifications/tools/list_changed", %{"_meta" => %{"seq" => 2}}} =
               Subscription.next(subscription, 1_000)
    end

    test "a full buffer drops the oldest event and reports the count",
         %{hub: hub, client: client} do
      {:ok, subscription} = Client.listen(client, @tools_filter, max_buffer: 2)
      %{id: id, ref: ref, pid: pid} = subscription

      for sequence <- 1..3, do: :ok = TestSubscriptionHub.emit(hub, id, tools_changed(sequence))

      assert eventually(fn ->
               %{buffer: buffer} = :sys.get_state(pid)
               buffer.size == 2 and buffer.dropped == 1
             end)

      :ok = Subscription.demand(subscription, 10)
      assert_receive {:snodo_subscription, ^ref, {:dropped, 1}}, 1_000
      assert_receive {:snodo_subscription, ^ref, {:notification, _method, second}}, 1_000
      assert second["_meta"]["seq"] == 2
      assert_receive {:snodo_subscription, ^ref, {:notification, _method, third}}, 1_000
      assert third["_meta"]["seq"] == 3
      refute_received {:snodo_subscription, ^ref, _other}
    end

    test "close/1 closes the connection, which the server takes as a disconnect",
         %{client: client} do
      {:ok, subscription} = Client.listen(client, @tools_filter)
      %{id: id, pid: pid} = subscription
      monitor = Process.monitor(pid)

      assert :ok = Subscription.close(subscription)
      assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 1_000
      assert_receive {:subscription_closed, ^id, reason}, 1_000
      assert disconnected?(reason)
      assert :ok = Subscription.close(subscription)
    end

    test "the owner's exit closes the connection", %{client: client} do
      test = self()

      owner =
        spawn(fn ->
          {:ok, subscription} = Client.listen(client, @tools_filter)
          send(test, {:listening, subscription})
          Process.sleep(:infinity)
        end)

      assert_receive {:listening, %Subscription{id: id, pid: pid}}, 1_000
      monitor = Process.monitor(pid)
      Process.exit(owner, :kill)

      assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 1_000
      assert_receive {:subscription_closed, ^id, reason}, 1_000
      assert disconnected?(reason)
    end

    test "the server's terminal result follows the queued events", %{hub: hub, client: client} do
      {:ok, subscription} = Client.listen(client, @tools_filter)
      %{id: id, ref: ref, pid: pid} = subscription
      monitor = Process.monitor(pid)

      :ok = TestSubscriptionHub.emit(hub, id, tools_changed(1))
      :ok = TestSubscriptionHub.emit(hub, id, tools_changed(2))
      :ok = TestSubscriptionHub.complete(hub, id)
      assert_receive {:subscription_closed, ^id, :complete}, 1_000

      assert {:notification, _method, %{"_meta" => %{"seq" => 1}}} =
               Subscription.next(subscription, 1_000)

      refute_receive {:snodo_subscription, ^ref, _payload}, 50

      assert {:notification, _method, %{"_meta" => %{"seq" => 2}}} =
               Subscription.next(subscription, 1_000)

      assert_receive {:snodo_subscription, ^ref, {:closed, :complete}}, 1_000
      assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 1_000
    end

    test "a source failure ends the stream with the server's error", %{hub: hub, client: client} do
      {:ok, subscription} = Client.listen(client, @tools_filter)
      id = subscription.id

      :ok = TestSubscriptionHub.fail(hub, id, :boom)

      assert {:closed, {:error, %Error{code: -32_603, kind: :execution}}} =
               Subscription.next(subscription, 1_000)

      assert_receive {:subscription_closed, ^id, {:error, :boom}}, 1_000
    end

    test "an error response is returned instead of a handle", %{client: client} do
      assert {:error, %Error{code: -32_602, kind: :protocol}} =
               Client.listen(client, %{"toolsListChanged" => "yes"})

      unconfigured =
        start_supervised!(
          Supervisor.child_spec({HTTPServer, runtime: TestFixtures.runtime(), port: 0},
            id: :unconfigured
          )
        )

      assert {:error, %Error{code: -32_601, kind: :protocol}} =
               Client.listen(connect(HTTPServer.url(unconfigured)), @tools_filter)

      refute_received {:subscription_opened, _id, _filter}
    end
  end

  describe "subscriptions against a fake server" do
    @acknowledgement %{
      "jsonrpc" => "2.0",
      "method" => "notifications/subscriptions/acknowledged",
      "params" => %{"notifications" => %{"toolsListChanged" => true}}
    }

    test "the request timeout bounds the wait for the acknowledgement, not the stream" do
      url =
        FakeHTTP.start(self(), fn _headers, _message ->
          silence = Stream.repeatedly(fn -> Process.sleep(50) && ": keepalive\n\n" end)
          {200, [{"content-type", "text/event-stream"}], {:stream, silence}}
        end)

      assert {:error, %Error{code: -32_001, data: %{"timeoutMs" => 200}}} =
               Client.listen(connect(url), %{"toolsListChanged" => true}, timeout: 200)

      url =
        FakeHTTP.start(self(), fn _headers, _message ->
          slow = Stream.map(events([@acknowledgement, event(1)]), &(Process.sleep(150) && &1))
          {200, [{"content-type", "text/event-stream"}], {:stream, slow}}
        end)

      {:ok, subscription} =
        Client.listen(connect(url), %{"toolsListChanged" => true}, timeout: 250)

      assert {:notification, _method, %{"seq" => 1}} = Subscription.next(subscription, 1_000)
    end

    test "a stream that ends before the acknowledgement, and a JSON error body, are errors" do
      empty =
        FakeHTTP.start(self(), fn _headers, _message ->
          {200, [{"content-type", "text/event-stream"}], ": nothing\n\n"}
        end)

      assert {:error, %Error{code: -32_000, kind: :transport, message: message}} =
               Client.listen(connect(empty), %{"toolsListChanged" => true})

      assert message =~ "before acknowledging"

      refused =
        FakeHTTP.start(self(), fn _headers, message ->
          error = %{"code" => -32_601, "message" => "no source"}
          body = JSON.encode!(%{"jsonrpc" => "2.0", "id" => message["id"], "error" => error})
          {404, [{"content-type", "application/json"}], body}
        end)

      assert {:error, %Error{code: -32_601, message: "no source"}} =
               Client.listen(connect(refused), %{"toolsListChanged" => true})
    end

    test "a connection that closes after the acknowledgement ends the stream with -32000" do
      url =
        FakeHTTP.start(self(), fn _headers, _message ->
          body = IO.iodata_to_binary(events([@acknowledgement, event(1)]))
          {200, [{"content-type", "text/event-stream"}], body}
        end)

      {:ok, subscription} = Client.listen(connect(url), %{"toolsListChanged" => true})
      assert {:notification, _method, %{"seq" => 1}} = Subscription.next(subscription, 1_000)

      assert {:closed, {:error, %Error{code: -32_000, kind: :transport, cause: :closed}}} =
               Subscription.next(subscription, 1_000)
    end

    test ":max_response_bytes applies to each event, not to the whole stream" do
      big = fn n -> event(n, String.duplicate("x", 400_000)) end

      url =
        FakeHTTP.start(self(), fn _headers, _message ->
          stream =
            events([
              @acknowledgement,
              big.(1),
              big.(2),
              big.(3),
              event(4, String.duplicate("x", 2 * @mib))
            ])

          {200, [{"content-type", "text/event-stream"}], {:stream, stream}}
        end)

      {:ok, subscription} =
        Client.listen(connect(url, max_response_bytes: @mib), %{"toolsListChanged" => true})

      for n <- 1..3 do
        assert {:notification, _method, %{"seq" => ^n}} = Subscription.next(subscription, 5_000)
      end

      assert {:closed, {:error, %Error{code: -32_000, cause: {:max_response_bytes, @mib}}}} =
               Subscription.next(subscription, 5_000)
    end

    defp event(sequence, padding \\ "") do
      %{
        "jsonrpc" => "2.0",
        "method" => "notifications/tools/list_changed",
        "params" => %{"seq" => sequence, "padding" => padding}
      }
    end

    defp events(messages) do
      Enum.map(messages, fn message -> "data: " <> JSON.encode!(message) <> "\n\n" end)
    end
  end

  defp tools_changed(sequence), do: Event.tools_list_changed(metadata: %{"seq" => sequence})

  defp disconnected?(:disconnected), do: true
  defp disconnected?({:disconnected, _socket_error}), do: true
  defp disconnected?(_reason), do: false

  defp eventually(check, attempts \\ 50) do
    Enum.any?(1..attempts, fn _attempt ->
      check.() || (Process.sleep(20) && false)
    end)
  end

  test "encode_sentinel/1 leaves printable ASCII alone and encodes everything else" do
    assert HTTP.encode_sentinel("echo") == "echo"
    assert HTTP.encode_sentinel("test://static/readme") == "test://static/readme"

    for value <- ["café", " padded", "line\nbreak", "=?base64?Zm9v?="] do
      assert HTTP.encode_sentinel(value) == "=?base64?" <> Base.encode64(value) <> "?="
    end
  end

  defp drain_progress do
    receive do
      {:snodo_progress, params} -> [params | drain_progress()]
    after
      0 -> []
    end
  end
end
