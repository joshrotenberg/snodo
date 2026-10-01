defmodule Snodo.ClientHTTPTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Snodo.Client
  alias Snodo.Client.HTTP
  alias Snodo.Client.Session
  alias Snodo.Client.Subscription
  alias Snodo.Error
  alias Snodo.Protocol.V2025_06_18
  alias Snodo.Protocol.V2025_11_25
  alias Snodo.Protocol.V2026_07_28
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

  defmodule NoToken do
    @moduledoc false
    @behaviour Snodo.Client.TokenProvider

    @impl true
    def token(_state, _context), do: {:ok, nil}

    @impl true
    def refresh(_state, _challenge, _context), do: {:ok, "unused"}
  end

  defmodule FakeHTTP do
    @moduledoc false
    # Answers each request with `respond.(headers, message)` and forwards what
    # it received to `owner`, so tests can assert on the exact wire request.
    # The HTTP method is in `headers` under `":method"`; a request without a
    # body (DELETE) arrives with `nil` as the message.
    #
    # `respond` returns `{status, headers, body}`, sent with a Content-Length;
    # `{status, headers, {:stream, chunks}}`, sent without one until a send
    # fails, after which the bytes sent go to `owner` as `{:fake_http_sent, n}`;
    # `{status, headers, {:hold, body}}`, sent without one on a connection that
    # stays open, while later requests are served, until the client closes it,
    # which is reported to `owner` as `:fake_http_closed`; or `{:raw, iodata}`,
    # sent as it is.

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
      message = read_body(socket, headers)
      send(owner, {:fake_http, headers, message})

      case respond.(headers, message) do
        {status, response_headers, {:hold, body}} ->
          hold(socket, owner, [head(status, response_headers), body])

        response ->
          _result = reply(socket, owner, response)
          :ok = :gen_tcp.close(socket)
      end

      accept(listen, owner, respond)
    end

    defp hold(socket, owner, data) do
      holder =
        spawn_link(fn ->
          receive do
            :hold ->
              :ok = :gen_tcp.send(socket, data)
              {:error, _closed} = :gen_tcp.recv(socket, 0)
              send(owner, :fake_http_closed)
          end
        end)

      :ok = :gen_tcp.controlling_process(socket, holder)
      send(holder, :hold)
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

    defp read_body(_socket, %{"content-length" => "0"}), do: nil
    defp read_body(_socket, headers) when not is_map_key(headers, "content-length"), do: nil

    defp read_body(socket, headers) do
      {:ok, body} = :gen_tcp.recv(socket, String.to_integer(headers["content-length"]))
      JSON.decode!(body)
    end

    defp read_headers(socket, headers) do
      case :gen_tcp.recv(socket, 0, 5_000) do
        {:ok, {:http_request, method, _uri, _version}} ->
          read_headers(socket, Map.put(headers, ":method", to_string(method)))

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

  # Pinned to 2026-07-28 unless the test negotiates: a fake server answers
  # every request the same way, so a probe would take its answer for a
  # legacy one.
  defp connect(url, opts \\ []) do
    {:ok, client} = Client.connect({:http, url}, Keyword.put_new(opts, :protocol, "2026-07-28"))
    client
  end

  defp negotiate(url, opts \\ []), do: Client.connect({:http, url}, opts)

  @initialized %{
    "protocolVersion" => "2025-11-25",
    "capabilities" => %{"tools" => %{}},
    "serverInfo" => %{"name" => "fake", "version" => "1"}
  }

  # A fake initialize-era server: initialize issues a session id, a
  # notification or a response object gets 202, and `answer` handles the rest.
  defp legacy_server(answer, session_id \\ "s-1") do
    FakeHTTP.start(self(), fn
      _headers, %{"method" => "initialize"} = message ->
        {200, [{"content-type", "application/json"}, {"mcp-session-id", session_id}],
         JSON.encode!(%{"jsonrpc" => "2.0", "id" => message["id"], "result" => @initialized})}

      _headers, %{"method" => "server/discover"} ->
        {404, [{"content-type", "text/plain"}], "Not Found"}

      _headers, %{"method" => _method, "id" => _id} = message ->
        answer.(message)

      _headers, _notification_or_response ->
        {202, [], ""}
    end)
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

    test "input handlers answer sampling and roots requests over HTTP" do
      sampled = %{
        "role" => "assistant",
        "content" => %{"type" => "text", "text" => "http"},
        "model" => "test-model"
      }

      roots = %{"roots" => [%{"uri" => "file:///http", "name" => "HTTP"}]}

      handlers = %{
        form: fn %{"mode" => "form"} ->
          {:ok, %{"action" => "accept", "content" => %{"label" => "http"}}}
        end,
        sampling: fn %{"messages" => [_message], "maxTokens" => 64} -> {:ok, sampled} end,
        roots: fn params when params == %{} -> {:ok, roots} end
      }

      url = serve(ChoiceServer.runtime())
      client = connect(url, input_handlers: handlers)

      assert {:ok, %{"structuredContent" => %{"summary" => "http", "model" => "test-model"}}} =
               Client.call_tool(client, "sample")

      assert {:ok, %{"structuredContent" => %{"uris" => ["file:///http"]}}} =
               Client.call_tool(client, "roots")

      # One round asks for all three kinds.
      assert {:ok, %{"structuredContent" => answers}} = Client.call_tool(client, "mixed")

      assert answers == %{
               "choice" => %{"action" => "accept", "content" => %{"label" => "http"}},
               "summary" => sampled,
               "client_roots" => roots
             }

      # An invalid result is refused before anything is sent.
      client =
        connect(url,
          input_handlers: %{roots: fn _params -> {:ok, %{"roots" => [%{"name" => "no uri"}]}} end}
        )

      assert {:error,
              %Error{
                code: -32_603,
                kind: :execution,
                cause: {:input_handler, "client_roots", {:invalid_response, _response}, _last}
              }} = Client.call_tool(client, "roots")
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
    test "request-level headers cannot set a header the transport owns" do
      {:ok, state} = HTTP.connect("http://127.0.0.1:1/mcp", [])
      message = %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list", "params" => %{}}
      notification = %{"jsonrpc" => "2.0", "method" => "notifications/initialized"}
      opts = [dialect: V2026_07_28, timeout: 1_000]

      for name <- ~w(Host content-length Content-Type transfer-encoding connection) do
        headers = [{name, "1"}]

        assert {:error, %Error{code: -32_000, cause: ^name}} =
                 HTTP.request(state, message, [headers: headers] ++ opts)

        assert {:error, %Error{code: -32_000, cause: ^name}} =
                 HTTP.notify(state, notification, [headers: headers] ++ opts)
      end

      # Authorization is the caller's to set unless a token provider owns it.
      headers = [headers: [{"Authorization", "Bearer x"}]]

      assert {:error, %Error{cause: {:failed_connect, _reason}}} =
               HTTP.request(state, message, headers ++ opts)

      {:ok, state} = HTTP.connect("http://127.0.0.1:1/mcp", token_provider: {NoToken, nil})

      assert {:error, %Error{code: -32_000, cause: "Authorization"}} =
               HTTP.request(state, message, headers ++ opts)
    end

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
      assert {:error, %Error{code: -32_602, data: %{"requested" => "2024-11-05"} = data}} =
               Client.connect({:http, "http://127.0.0.1:1/mcp"}, protocol: "2024-11-05")

      assert data["supported"] == ["2026-07-28", "2025-11-25", "2025-06-18"]
    end

    test "with probing, an unreachable endpoint fails at connect" do
      {:ok, listen} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
      {:ok, port} = :inet.port(listen)
      :ok = :gen_tcp.close(listen)

      assert {:error, %Error{code: -32_000, kind: :transport, cause: {:failed_connect, _}}} =
               negotiate("http://127.0.0.1:#{port}/mcp")
    end
  end

  describe "version negotiation against the native listener" do
    test "a 2026-07-28 server answers the probe and no handshake follows" do
      url = serve(TestFixtures.runtime(protocols: [V2026_07_28, V2025_11_25]))

      assert {:ok, %Client{protocol: "2026-07-28", session: nil} = client} = negotiate(url)

      assert {:ok, %{"supportedVersions" => ["2026-07-28", "2025-11-25"]}} =
               Client.discover(client)

      assert {:ok, [_tool | _rest]} = Client.list_tools(client)
    end

    test "a server with only initialize-era dialects is initialized after the probe fails" do
      url =
        serve(
          TestFixtures.runtime(
            resources: [StaticText],
            prompts: [PackageAnalysis],
            protocols: [V2025_11_25, V2025_06_18],
            instructions: "Legacy only."
          )
        )

      assert {:ok, %Client{protocol: "2025-11-25", dialect: V2025_11_25} = client} =
               negotiate(url)

      assert %Session{
               version: "2025-11-25",
               id: nil,
               server_info: %{"name" => "snodo-spike", "version" => "0.1.0"},
               server_capabilities: %{"tools" => %{}, "resources" => %{}, "prompts" => %{}},
               instructions: "Legacy only."
             } = client.session

      assert {:ok, tools} = Client.list_tools(client)
      assert Enum.any?(tools, &(&1["name"] == "echo"))
      refute Enum.any?(tools, &(&1["name"] == "complex_schema"))

      assert {:ok, %{"content" => [%{"text" => "over HTTP"}]} = result} =
               Client.call_tool(client, "echo", %{"text" => "over HTTP"})

      refute Map.has_key?(result, "resultType")

      assert {:ok, %{"contents" => [%{"uri" => "test://static/readme"}]}} =
               Client.read_resource(client, "test://static/readme")

      assert {:ok, %{"messages" => [_message | _rest]}} =
               Client.get_prompt(client, "package_analysis", %{"name" => "plug"})

      assert {:ok, %{}} = Client.ping(client)

      assert {:error, %Error{code: -32_602, kind: :protocol}} =
               Client.call_tool(client, "missing")

      assert {:error, %Error{code: -32_601}} = Client.discover(client)
      assert :ok = Client.close(client)
    end

    test "a pin or a list from one era skips the probe" do
      url = serve(TestFixtures.runtime(protocols: [V2026_07_28, V2025_11_25, V2025_06_18]))

      assert {:ok,
              %Client{protocol: "2025-06-18", session: %Session{version: "2025-06-18"}} = client} =
               negotiate(url, protocol: "2025-06-18")

      assert {:ok, [tool | _rest]} = Client.list_tools(client)
      refute Map.has_key?(tool, "icons")

      assert {:ok, %Client{protocol: "2025-11-25"}} =
               negotiate(url, protocol: ["2025-06-18", "2025-11-25"])

      assert {:ok, %Client{protocol: "2026-07-28", session: nil}} =
               negotiate(url, protocol: ["2025-11-25", "2026-07-28"])
    end

    test "a version the server negotiates outside the allowed list ends the connection" do
      url = serve(TestFixtures.runtime(protocols: [V2025_11_25]))

      assert {:error,
              %Error{
                code: -32_602,
                data: %{"negotiated" => "2025-11-25", "requested" => ["2025-06-18"]}
              }} = negotiate(url, protocol: ["2026-07-28", "2025-06-18"])
    end

    test "progress reaches the caller on an initialize-era connection" do
      url = serve(TestFixtures.runtime(tools: [Ticks], protocols: [V2025_06_18]))
      {:ok, client} = negotiate(url)

      assert {:ok, %{"content" => [%{"text" => "ticked 2"}]}} =
               Client.call_tool(client, "ticks", %{"count" => 2}, progress: self())

      assert [%{"progress" => 1}, %{"progress" => 2}] = drain_progress()
    end
  end

  describe "initialize-era sessions against a fake server" do
    test "the session id and the protocol version travel on every later request and the DELETE" do
      url = legacy_server(&json(&1, %{"tools" => []}))

      assert {:ok, %Client{session: %Session{id: "s-1", version: "2025-11-25"}} = client} =
               negotiate(url, client_capabilities: %{"elicitation" => %{}})

      assert_receive {:fake_http, probe_headers, %{"method" => "server/discover"}}, 1_000
      assert probe_headers["mcp-protocol-version"] == "2026-07-28"

      assert_receive {:fake_http, headers, %{"method" => "initialize"} = initialize}, 1_000
      refute Map.has_key?(headers, "mcp-protocol-version")
      refute Map.has_key?(headers, "mcp-session-id")
      refute Map.has_key?(headers, "mcp-method")
      assert headers["content-type"] == "application/json"
      assert headers["accept"] == "application/json, text/event-stream"
      assert initialize["params"]["protocolVersion"] == "2025-11-25"
      assert initialize["params"]["capabilities"] == %{"elicitation" => %{}}
      assert initialize["params"]["clientInfo"]["name"] == "snodo"
      refute Map.has_key?(initialize["params"], "_meta")

      assert_receive {:fake_http, headers, %{"method" => "notifications/initialized"} = note},
                     1_000

      refute Map.has_key?(note, "id")
      assert headers["mcp-protocol-version"] == "2025-11-25"
      assert headers["mcp-session-id"] == "s-1"

      assert {:ok, []} = Client.list_tools(client)
      assert_receive {:fake_http, headers, %{"method" => "tools/list"}}, 1_000
      assert headers["mcp-protocol-version"] == "2025-11-25"
      assert headers["mcp-session-id"] == "s-1"
      refute Map.has_key?(headers, "mcp-method")

      assert :ok = Client.close(client)
      assert_receive {:fake_http, %{":method" => "DELETE"} = headers, nil}, 1_000
      assert headers["mcp-protocol-version"] == "2025-11-25"
      assert headers["mcp-session-id"] == "s-1"
    end

    test "a server request on the event stream is answered on its own POST with the session headers" do
      form = fn %{"message" => "Name?"} ->
        {:ok, %{"action" => "accept", "content" => %{"name" => "Ada"}}}
      end

      url =
        legacy_server(fn %{"method" => "tools/call"} = message ->
          request = %{
            "jsonrpc" => "2.0",
            "id" => "srv-1",
            "method" => "elicitation/create",
            "params" => %{
              "mode" => "form",
              "message" => "Name?",
              "requestedSchema" => %{"type" => "object"}
            }
          }

          ping = %{"jsonrpc" => "2.0", "id" => "srv-2", "method" => "ping"}

          result = %{
            "jsonrpc" => "2.0",
            "id" => message["id"],
            "result" => %{"content" => [%{"type" => "text", "text" => "asked"}]}
          }

          body =
            Enum.map_join([request, ping, result], fn event ->
              "data: #{JSON.encode!(event)}\n\n"
            end)

          {200, [{"content-type", "text/event-stream"}], body}
        end)

      {:ok, client} = negotiate(url, input_handlers: %{form: form})

      assert {:ok, %{"content" => [%{"text" => "asked"}]}} = Client.call_tool(client, "ask")

      assert_receive {:fake_http, headers, %{"id" => "srv-1", "result" => answer} = response},
                     1_000

      assert answer == %{"action" => "accept", "content" => %{"name" => "Ada"}}
      refute Map.has_key?(response, "method")
      assert headers["mcp-session-id"] == "s-1"
      assert headers["mcp-protocol-version"] == "2025-11-25"
      assert headers["content-type"] == "application/json"
      assert_receive {:fake_http, _headers, %{"id" => "srv-2", "result" => %{}}}, 1_000

      # Without a handler for the kind, the server gets -32601 and the call
      # still completes with what the server then sends.
      {:ok, client} = negotiate(url)
      assert {:ok, %{"content" => [%{"text" => "asked"}]}} = Client.call_tool(client, "ask")

      assert_receive {:fake_http, _headers, %{"id" => "srv-1", "error" => %{"code" => -32_601}}},
                     1_000
    end

    test "sampling and roots requests on the event stream reach their handlers" do
      message = %{
        "role" => "assistant",
        "content" => %{"type" => "text", "text" => "hi"},
        "model" => "m"
      }

      roots = %{"roots" => [%{"uri" => "file:///work"}]}

      url =
        legacy_server(fn %{"method" => "tools/call"} = call ->
          events = [
            %{
              "jsonrpc" => "2.0",
              "id" => "srv-1",
              "method" => "sampling/createMessage",
              "params" => %{"messages" => [], "maxTokens" => 5}
            },
            %{"jsonrpc" => "2.0", "id" => "srv-2", "method" => "roots/list"},
            %{
              "jsonrpc" => "2.0",
              "id" => call["id"],
              "result" => %{"content" => [%{"type" => "text", "text" => "done"}]}
            }
          ]

          body = Enum.map_join(events, &"data: #{JSON.encode!(&1)}\n\n")
          {200, [{"content-type", "text/event-stream"}], body}
        end)

      {:ok, client} =
        negotiate(url,
          input_handlers: %{
            sampling: fn %{"maxTokens" => 5} -> {:ok, message} end,
            roots: fn %{} -> {:ok, roots} end
          }
        )

      assert client.client_capabilities["sampling"] == %{}
      assert {:ok, %{"content" => [%{"text" => "done"}]}} = Client.call_tool(client, "ask")

      assert_receive {:fake_http, headers, %{"id" => "srv-1", "result" => ^message}}, 1_000
      assert headers["mcp-session-id"] == "s-1"
      assert_receive {:fake_http, _headers, %{"id" => "srv-2", "result" => ^roots}}, 1_000
    end

    test "a probe that times out, or gets a body that is not JSON-RPC, falls back to initialize" do
      keepalive = Stream.repeatedly(fn -> Process.sleep(50) && ": keepalive\n\n" end)

      url =
        FakeHTTP.start(self(), fn
          _headers, %{"method" => "server/discover"} ->
            {200, [{"content-type", "text/event-stream"}], {:stream, keepalive}}

          _headers, %{"method" => "initialize"} = message ->
            json(message, @initialized)

          _headers, _other ->
            {202, [], ""}
        end)

      assert {:ok, %Client{protocol: "2025-11-25"}} = negotiate(url, probe_timeout: 200)
      assert_receive {:fake_http_sent, _bytes}, 5_000

      url = legacy_server(&json(&1, %{}), "")
      assert {:ok, %Client{session: %Session{id: nil}} = client} = negotiate(url)
      assert :ok = Client.close(client)
      refute_received {:fake_http, %{":method" => "DELETE"}, nil}
    end

    test "a refused answer to a server request fails the request in flight at once" do
      elicitation = %{
        "jsonrpc" => "2.0",
        "id" => "srv-1",
        "method" => "elicitation/create",
        "params" => %{"mode" => "form", "message" => "Name?", "requestedSchema" => %{}}
      }

      refusal = ~s({"jsonrpc":"2.0","id":null,"error":{"code":-32600,"message":"Unknown"}})

      url =
        FakeHTTP.start(self(), fn
          _headers, %{"method" => "initialize"} = message ->
            json(message, @initialized)

          _headers, %{"method" => "tools/call"} ->
            event = "data: #{JSON.encode!(elicitation)}\n\n"
            {200, [{"content-type", "text/event-stream"}], {:hold, event}}

          _headers, %{"id" => "srv-1"} ->
            {400, [@json_type], refusal}

          _headers, _notification ->
            {202, [], ""}
        end)

      form = fn _params -> {:ok, %{"action" => "decline"}} end

      {:ok, client} =
        negotiate(url, protocol: "2025-11-25", timeout: 5_000, input_handlers: %{form: form})

      started = System.monotonic_time(:millisecond)

      assert {:error, %Error{code: -32_000, kind: :transport, message: message, cause: cause}} =
               Client.call_tool(client, "ask")

      assert System.monotonic_time(:millisecond) - started < 4_000
      assert message =~ "refused the answer to its elicitation/create request"
      assert %Error{code: -32_600, message: "Unknown", kind: :protocol} = cause
      assert_receive {:fake_http, _headers, %{"id" => "srv-1", "result" => _answer}}, 1_000
      assert_receive :fake_http_closed, 1_000
    end

    test "a failed initialize leaves no header report in the caller's mailbox" do
      error = %{"code" => -32_602, "message" => "Unsupported"}

      for outcome <- [%{"result" => %{}}, %{"error" => error}] do
        url =
          FakeHTTP.start(self(), fn _headers, message ->
            body = JSON.encode!(Map.merge(%{"jsonrpc" => "2.0", "id" => message["id"]}, outcome))
            {200, [@json_type], body}
          end)

        assert {:error, %Error{}} = negotiate(url, protocol: "2025-11-25")
        assert_receive {:fake_http, _headers, %{"method" => "initialize"}}, 1_000
        refute header_report?()
      end
    end

    defp header_report? do
      receive do
        {ref, headers} when is_reference(ref) and is_list(headers) -> true
      after
        0 -> false
      end
    end

    test "an initialized notification the server refuses ends the connection" do
      url =
        FakeHTTP.start(self(), fn
          _headers, %{"method" => "initialize"} = message ->
            json(message, @initialized)

          _headers, %{"method" => "notifications/initialized"} ->
            body = ~s({"jsonrpc":"2.0","id":null,"error":{"code":-32000,"message":"No session"}})
            {400, [{"content-type", "application/json"}], body}
        end)

      assert {:error, %Error{code: -32_000, message: "No session", kind: :protocol}} =
               negotiate(url, protocol: "2025-11-25")

      url =
        FakeHTTP.start(self(), fn
          _headers, %{"method" => "initialize"} = message -> json(message, @initialized)
          _headers, _other -> {500, [], "boom"}
        end)

      assert {:error, %Error{code: -32_000, kind: :transport, cause: {:http_status, 500, "boom"}}} =
               negotiate(url, protocol: "2025-11-25")
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

      assert {:closed, {:error, %Error{code: -32_000, message: "The subscription has ended"}}} =
               Subscription.next(subscription, 1_000)
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

      assert {:closed, {:error, %Error{code: -32_000, message: "The subscription has ended"}}} =
               Subscription.next(subscription, 1_000)
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

      # The event comes longer after the acknowledgement than the timeout,
      # so neither the original deadline nor a fresh one may apply to it.
      url =
        FakeHTTP.start(self(), fn _headers, _message ->
          paced =
            Stream.map(Enum.zip([50, 600], events([@acknowledgement, event(1)])), fn
              {pause, chunk} -> Process.sleep(pause) && chunk
            end)

          {200, [{"content-type", "text/event-stream"}], {:stream, paced}}
        end)

      {:ok, subscription} =
        Client.listen(connect(url), %{"toolsListChanged" => true}, timeout: 250)

      assert {:notification, _method, %{"seq" => 1}} = Subscription.next(subscription, 2_000)
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

    test ":max_response_bytes is not applied to a read that holds several events" do
      body = IO.iodata_to_binary(events([@acknowledgement | Enum.map(1..30, &event/1)]))
      assert byte_size(body) > 3_000
      sse = "content-type: text/event-stream\r\n"
      chunk = [Integer.to_string(byte_size(body), 16), "\r\n", body, "\r\n0\r\n\r\n"]

      responses = [
        {200, [{"content-type", "text/event-stream"}], body},
        {200, [{"content-type", "text/event-stream"}], {:stream, [body]}},
        {:raw, ["HTTP/1.1 200 OK\r\n", sse, "transfer-encoding: chunked\r\n\r\n", chunk]}
      ]

      for response <- responses do
        url = FakeHTTP.start(self(), fn _headers, _message -> response end)

        {:ok, subscription} =
          Client.listen(connect(url, max_response_bytes: 1_000), %{"toolsListChanged" => true})

        for n <- 1..30 do
          assert {:notification, _method, %{"seq" => ^n}} =
                   Subscription.next(subscription, 1_000)
        end

        assert {:closed, {:error, %Error{code: -32_000, cause: :closed}}} =
                 Subscription.next(subscription, 1_000)
      end
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
