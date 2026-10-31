defmodule Snodo.SessionHTTPTest do
  use ExUnit.Case, async: true

  alias Snodo.Client
  alias Snodo.Elicitation
  alias Snodo.Protocol.{V2025_06_18, V2025_11_25, V2026_07_28}
  alias Snodo.Result
  alias Snodo.Session.Manager
  alias Snodo.Subscription.Hub
  alias Snodo.Transport.StreamableHTTP.Server, as: HTTPServer
  alias SnodoTest.TestFixtures
  alias SnodoTest.TestTools.{Echo, Trapping}

  defmodule Rounds do
    @moduledoc false
    use Snodo.Tool, name: "rounds"

    # Two rounds of input. The first answer travels to the second round in
    # requestState, since each round carries only its own answers.
    @impl true
    def call(_arguments, context) do
      :ok = Snodo.Progress.report(context, progress(context))

      case {context.request_state, Elicitation.response(context, "name", field("name"))} do
        {nil, :missing} ->
          {:ok, Result.input_required(input_requests: %{"name" => field("name")})}

        {nil, {:ok, %{"content" => %{"name" => name}}}} ->
          {:ok,
           Result.input_required(
             input_requests: %{"color" => field("color")},
             request_state: name
           )}

        {name, _none} ->
          case Elicitation.response(context, "color", field("color")) do
            {:ok, %{"content" => %{"color" => color}}} ->
              {:ok, Result.text("#{name} likes #{color}")}

            other ->
              {:ok, Result.text(inspect(other))}
          end
      end
    end

    defp progress(%{request_state: nil, input_responses: responses}) when responses == %{}, do: 1
    defp progress(%{request_state: nil}), do: 2
    defp progress(_context), do: 3

    def field(name) do
      Elicitation.form("Your #{name}?", %{
        "type" => "object",
        "properties" => %{name => %{"type" => "string"}},
        "required" => [name]
      })
    end
  end

  defmodule Sample do
    @moduledoc false
    use Snodo.Tool, name: "sample"

    @impl true
    def call(_arguments, context) do
      request =
        Snodo.Sampling.create_message(
          [Snodo.Prompt.message(:user, Snodo.Prompt.text("Hi"))],
          max_tokens: 10
        )

      case Snodo.Sampling.response(context, "reply", request) do
        :missing ->
          {:ok, Result.input_required(input_requests: %{"reply" => request})}

        {:ok, %{"content" => %{"text" => text}, "model" => model}} ->
          {:ok, Result.text("#{model}: #{text}")}
      end
    end
  end

  defmodule ClientRoots do
    @moduledoc false
    use Snodo.Tool, name: "client_roots"

    @impl true
    def call(_arguments, context) do
      case Snodo.Roots.response(context, "roots", Snodo.Roots.list()) do
        :missing ->
          {:ok, Result.input_required(input_requests: %{"roots" => Snodo.Roots.list()})}

        {:ok, %{"roots" => roots}} ->
          {:ok, Result.text(Enum.map_join(roots, ",", & &1["uri"]))}
      end
    end
  end

  defmodule Endless do
    @moduledoc false
    use Snodo.Tool, name: "endless"

    @impl true
    def call(_arguments, _context) do
      {:ok, Result.input_required(input_requests: %{"again" => Rounds.field("again")})}
    end
  end

  defmodule HeaderGate do
    @moduledoc false
    @behaviour Snodo.Transport.StreamableHTTP.RequestGate

    @impl true
    def init(_opts, _listener), do: nil

    @impl true
    def check(request, _state) do
      user =
        Enum.find_value(request.headers, fn {name, value} -> if name == "x-user", do: value end)

      {:ok, %{principal: user}}
    end
  end

  defmodule Watched do
    @moduledoc false
    use Snodo.Resource, uri: "test://watched", name: "watched"

    @impl true
    def read(%{"uri" => uri}, _context),
      do: {:ok, Result.resource_read(Snodo.Resource.text(uri, "watched"))}
  end

  @legacy [V2026_07_28, V2025_11_25, V2025_06_18]

  setup do
    hub = start_supervised!(Hub)
    %{hub: hub}
  end

  defp runtime(hub) do
    TestFixtures.runtime(
      tools: [Echo, Trapping, Rounds, Sample, ClientRoots, Endless],
      resources: [Watched],
      protocols: @legacy,
      capabilities: %{"tools" => %{"listChanged" => true}, "resources" => %{"subscribe" => true}},
      subscription_source: Hub.source(hub)
    )
  end

  defp listen(runtime, opts \\ []) do
    server =
      start_supervised!({HTTPServer, Keyword.merge([runtime: runtime, sessions: true], opts)})

    {_ip, port, _path} = HTTPServer.address(server)
    %{server: server, port: port, url: HTTPServer.url(server)}
  end

  describe "the session lifecycle" do
    test "initialize issues an ID that later requests need, and DELETE ends it", %{hub: hub} do
      %{port: port} = listen(runtime(hub))

      assert %{status: 200, headers: headers, body: body} = initialize(port, "2025-11-25")
      id = headers["mcp-session-id"]
      assert id =~ ~r/\A[\x21-\x7E]{32}\z/

      assert %{"result" => %{"capabilities" => capabilities}} = JSON.decode!(body)
      assert capabilities["resources"] == %{"subscribe" => true}
      assert capabilities["tools"] == %{"listChanged" => true}

      assert %{status: 400} = post(port, request(2, "tools/list"), "2025-11-25", nil)

      assert %{status: 404, body: missing} =
               post(port, request(2, "tools/list"), "2025-11-25", "unknown")

      assert %{"error" => %{"code" => -32_001}} = JSON.decode!(missing)

      assert %{status: 200} = post(port, request(2, "tools/list"), "2025-11-25", id)
      assert %{status: 400} = post(port, request(3, "tools/list"), "2025-06-18", id)

      assert %{status: 200} = raw_request(port, "DELETE", session_headers("2025-11-25", id), "")
      assert %{status: 404} = post(port, request(4, "tools/list"), "2025-11-25", id)

      # The client initializes again and gets a new session.
      assert %{status: 200, headers: %{"mcp-session-id" => second}} =
               initialize(port, "2025-11-25")

      assert second != id
      assert %{status: 200} = post(port, request(5, "tools/list"), "2025-11-25", second)
    end

    test "a failed initialize leaves no session", %{hub: hub} do
      %{server: server, port: port} = listen(runtime(hub))
      invalid = request(1, "initialize", %{"protocolVersion" => "2025-11-25"})

      assert %{status: 200, headers: headers, body: body} = post(port, invalid, nil, nil)
      refute Map.has_key?(headers, "mcp-session-id")
      assert %{"error" => %{"code" => -32_602}} = JSON.decode!(body)
      assert Manager.count(manager(server)) == 0
    end

    test "2026-07-28 requests are not part of a session", %{hub: hub} do
      %{port: port} = listen(runtime(hub))
      raw = TestFixtures.request(1, "tools/list")

      headers = [
        {"Content-Type", "application/json"},
        {"Accept", "application/json, text/event-stream"},
        {"MCP-Protocol-Version", "2026-07-28"},
        {"Mcp-Method", "tools/list"}
      ]

      assert %{status: 200, headers: response_headers} =
               raw_request(port, "POST", headers, JSON.encode!(raw))

      refute Map.has_key?(response_headers, "mcp-session-id")
    end

    test "without sessions the dialects issue no ID and refuse session methods", %{hub: hub} do
      server = start_supervised!({HTTPServer, runtime: runtime(hub)})
      {_ip, port, _path} = HTTPServer.address(server)

      assert %{status: 200, headers: headers, body: body} = initialize(port, "2025-11-25")
      refute Map.has_key?(headers, "mcp-session-id")
      assert %{"result" => %{"capabilities" => %{"resources" => %{}}}} = JSON.decode!(body)

      assert %{body: refused} =
               post(
                 port,
                 request(2, "resources/subscribe", %{"uri" => "test://watched"}),
                 "2025-11-25",
                 nil
               )

      assert %{"error" => %{"code" => -32_601}} = JSON.decode!(refused)
      assert %{status: 405} = raw_request(port, "GET", session_headers("2025-11-25", "x"), "")
    end

    test "a session is bound to the principal that created it", %{hub: hub} do
      %{port: port} = listen(runtime(hub), request_gate: {HeaderGate, []})

      assert %{status: 200, headers: %{"mcp-session-id" => id}} =
               initialize(port, "2025-11-25", [{"x-user", "alice"}])

      assert %{status: 404} =
               post(port, request(2, "tools/list"), "2025-11-25", id, [{"x-user", "bob"}])

      assert %{status: 200} =
               post(port, request(2, "tools/list"), "2025-11-25", id, [{"x-user", "alice"}])
    end

    test "an idle session expires and its ID answers 404", %{hub: hub} do
      %{server: server, port: port} = listen(runtime(hub), sessions: [idle_timeout: 50])

      assert %{headers: %{"mcp-session-id" => id}} = initialize(port, "2025-11-25")
      config = manager(server)
      {module, options} = config.registry
      {:ok, pid} = module.lookup(options, id)
      monitor = Process.monitor(pid)

      assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}
      assert %{status: 404} = post(port, request(2, "tools/list"), "2025-11-25", id)
    end

    test "max_sessions bounds open sessions with 503", %{hub: hub} do
      %{port: port} = listen(runtime(hub), sessions: [max_sessions: 1])

      assert %{status: 200, headers: %{"mcp-session-id" => id}} = initialize(port, "2025-11-25")
      assert %{status: 503, headers: headers} = initialize(port, "2025-11-25")
      refute Map.has_key?(headers, "mcp-session-id")

      assert %{status: 200} = raw_request(port, "DELETE", session_headers("2025-11-25", id), "")
      assert %{status: 200} = initialize(port, "2025-11-25")
    end
  end

  describe "input requests" do
    test "go out on the request's event stream and come back as POSTs", %{hub: hub} do
      %{port: port} = listen(runtime(hub))

      %{headers: %{"mcp-session-id" => id}} =
        initialize(port, "2025-11-25", [], %{"elicitation" => %{}})

      call =
        request(7, "tools/call", %{
          "name" => "rounds",
          "arguments" => %{},
          "_meta" => %{"progressToken" => "p"}
        })

      socket = open_post(port, call, "2025-11-25", id)

      {first, buffer} = next_event(socket, "")
      assert %{"method" => "notifications/progress", "params" => %{"progress" => 1}} = first
      {ask, buffer} = next_event(socket, buffer)

      assert %{"id" => ask_id, "method" => "elicitation/create", "params" => params} = ask
      assert params["mode"] == "form"
      assert %{status: 202} = post(port, answer(ask_id, "name", "Ada"), "2025-11-25", id)

      {%{"params" => %{"progress" => 2}}, buffer} = next_event(socket, buffer)
      {%{"id" => color_id, "method" => "elicitation/create"}, buffer} = next_event(socket, buffer)
      assert color_id != ask_id
      assert %{status: 202} = post(port, answer(color_id, "color", "green"), "2025-11-25", id)

      {%{"params" => %{"progress" => 3}}, buffer} = next_event(socket, buffer)
      {result, _buffer} = next_event(socket, buffer)
      assert %{"id" => 7, "result" => %{"content" => [%{"text" => "Ada likes green"}]}} = result
      :gen_tcp.close(socket)
    end

    for version <- ["2025-11-25", "2025-06-18"] do
      test "Snodo.Client answers elicitation, sampling, and roots on #{version}", %{hub: hub} do
        %{url: url} = listen(runtime(hub))
        test = self()

        handlers = %{
          form: fn params ->
            send(test, {:form, params})
            [name] = Map.keys(params["requestedSchema"]["properties"])
            {:ok, %{"action" => "accept", "content" => %{name => "Ada"}}}
          end,
          sampling: fn _params ->
            {:ok,
             %{
               "role" => "assistant",
               "content" => %{"type" => "text", "text" => "hello"},
               "model" => "test-model"
             }}
          end,
          roots: fn _params -> {:ok, %{"roots" => [%{"uri" => "file:///work"}]}} end
        }

        {:ok, client} =
          Client.connect({:http, url}, protocol: unquote(version), input_handlers: handlers)

        assert {:ok, %{"content" => [%{"text" => "Ada likes Ada"}]}} =
                 Client.call_tool(client, "rounds", %{})

        assert_receive {:form, form}
        assert Map.has_key?(form, "mode") == (unquote(version) == "2025-11-25")

        assert {:ok, %{"content" => [%{"text" => "test-model: hello"}]}} =
                 Client.call_tool(client, "sample", %{})

        assert {:ok, %{"content" => [%{"text" => "file:///work"}]}} =
                 Client.call_tool(client, "client_roots", %{})

        Client.close(client)
      end
    end

    test "a refused input request fails the call with the client's error", %{hub: hub} do
      %{url: url} = listen(runtime(hub))
      handlers = %{form: fn _params -> {:error, :no_user} end}

      {:ok, client} =
        Client.connect({:http, url}, protocol: "2025-11-25", input_handlers: handlers)

      assert {:error, %Snodo.Error{message: "The client refused an input request: " <> _}} =
               Client.call_tool(client, "rounds", %{})

      Client.close(client)
    end

    test "a handler that keeps asking ends after the round limit", %{hub: hub} do
      %{url: url} = listen(runtime(hub))
      handlers = %{form: fn _params -> {:ok, %{"action" => "accept", "content" => %{}}} end}

      {:ok, client} =
        Client.connect({:http, url}, protocol: "2025-11-25", input_handlers: handlers)

      assert {:error, %Snodo.Error{code: -32_603, message: message}} =
               Client.call_tool(client, "endless", %{})

      assert message =~ "after 10 rounds"
      Client.close(client)
    end

    test "a client without the capability gets -32021 and no request", %{hub: hub} do
      %{port: port} = listen(runtime(hub))
      %{headers: %{"mcp-session-id" => id}} = initialize(port, "2025-11-25")

      assert %{status: 200, body: body} =
               post(port, request(2, "tools/call", %{"name" => "sample"}), "2025-11-25", id)

      assert %{"error" => %{"code" => -32_021}} = JSON.decode!(body)
    end
  end

  test "notifications/cancelled cancels a request in flight on the session", %{hub: hub} do
    %{port: port} = listen(runtime(hub))
    %{headers: %{"mcp-session-id" => id}} = initialize(port, "2025-11-25")

    token = Integer.to_string(System.unique_integer([:positive]))
    :yes = :global.register_name({Trapping, token}, self())
    on_exit(fn -> :global.unregister_name({Trapping, token}) end)

    call =
      request("slow", "tools/call", %{"name" => "trapping", "arguments" => %{"token" => token}})

    socket = open_post(port, call, "2025-11-25", id)
    assert_receive {:trapping_entered, worker, cancellation}
    monitor = Process.monitor(worker)

    cancel = %{
      "jsonrpc" => "2.0",
      "method" => "notifications/cancelled",
      "params" => %{"requestId" => "slow", "reason" => "test"}
    }

    assert %{status: 202} = post(port, cancel, "2025-11-25", id)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}
    assert Snodo.Cancellation.cancelled?(cancellation)
    :gen_tcp.close(socket)
  end

  describe "the standalone stream" do
    test "carries list changes and subscribed resource updates, one per session", %{hub: hub} do
      %{port: port} = listen(runtime(hub))
      %{headers: %{"mcp-session-id" => id}} = initialize(port, "2025-11-25")

      assert %{status: 406} =
               raw_request(
                 port,
                 "GET",
                 [{"Mcp-Session-Id", id}, {"Accept", "application/json"}],
                 ""
               )

      assert %{status: 400} =
               raw_request(port, "GET", [{"Accept", "text/event-stream"}], "")

      stream = open_stream(port, id)
      assert %{status: 409} = raw_request(port, "GET", stream_headers(id), "")

      {:ok, _report} = Hub.notify_tools_list_changed(hub)
      {event, buffer} = next_event(stream, "")
      assert event == %{"jsonrpc" => "2.0", "method" => "notifications/tools/list_changed"}

      subscribe = request(2, "resources/subscribe", %{"uri" => "test://watched"})
      assert %{status: 200, body: body} = post(port, subscribe, "2025-11-25", id)
      assert %{"result" => %{}} = JSON.decode!(body)

      {:ok, _report} = Hub.notify_resource_updated(hub, "test://watched")
      {updated, buffer} = next_event(stream, buffer)

      assert %{
               "method" => "notifications/resources/updated",
               "params" => %{"uri" => "test://watched"}
             } = updated

      unsubscribe = request(3, "resources/unsubscribe", %{"uri" => "test://watched"})
      assert %{status: 200} = post(port, unsubscribe, "2025-11-25", id)

      {:ok, _report} = Hub.notify_resource_updated(hub, "test://watched")
      {:ok, _report} = Hub.notify_tools_list_changed(hub)
      {next, _buffer} = next_event(stream, buffer)
      assert next["method"] == "notifications/tools/list_changed"

      :gen_tcp.close(stream)
    end

    test "a closed stream can be opened again, and DELETE ends an open one", %{hub: hub} do
      %{port: port} = listen(runtime(hub))
      %{headers: %{"mcp-session-id" => id}} = initialize(port, "2025-11-25")

      first = open_stream(port, id)
      :gen_tcp.close(first)

      second = reopen_stream(port, id)
      assert %{status: 200} = raw_request(port, "DELETE", session_headers("2025-11-25", id), "")
      assert {:error, :closed} = recv_closed(second)
    end
  end

  # Helpers.

  defp manager(server), do: Manager.config(:sys.get_state(server).session_manager)

  defp request(id, method, params \\ %{}),
    do: %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}

  defp answer(id, field, value),
    do: %{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => %{"action" => "accept", "content" => %{field => value}}
    }

  defp initialize(port, version, extra \\ [], capabilities \\ %{}) do
    raw =
      request(1, "initialize", %{
        "protocolVersion" => version,
        "capabilities" => capabilities,
        "clientInfo" => %{"name" => "session-test", "version" => "1"}
      })

    post(port, raw, nil, nil, extra)
  end

  defp post(port, raw, version, session, extra \\ []) do
    raw_request(port, "POST", post_headers(version, session) ++ extra, JSON.encode!(raw))
  end

  defp post_headers(version, session) do
    [{"Content-Type", "application/json"}, {"Accept", "application/json, text/event-stream"}] ++
      session_headers(version, session)
  end

  defp session_headers(version, session) do
    if(version, do: [{"MCP-Protocol-Version", version}], else: []) ++
      if(session, do: [{"Mcp-Session-Id", session}], else: [])
  end

  defp stream_headers(id),
    do: [
      {"Accept", "text/event-stream"},
      {"MCP-Protocol-Version", "2025-11-25"},
      {"Mcp-Session-Id", id}
    ]

  defp raw_request(port, method, headers, body) do
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])
    :ok = :gen_tcp.send(socket, encoded(method, headers, body))
    response = recv_all(socket, "")
    parse_response(response)
  end

  defp open_post(port, raw, version, session) do
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])

    :ok =
      :gen_tcp.send(socket, encoded("POST", post_headers(version, session), JSON.encode!(raw)))

    socket
  end

  defp open_stream(port, id) do
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])
    :ok = :gen_tcp.send(socket, encoded("GET", stream_headers(id), ""))
    head = recv_until(socket, "\r\n\r\n", "")
    assert head =~ "HTTP/1.1 200"
    assert head =~ "text/event-stream"
    socket
  end

  # The session notices a closed stream when its connection process exits,
  # so a new GET can race it; the second attempt waits for that DOWN.
  defp reopen_stream(port, id, attempts \\ 50) do
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])
    :ok = :gen_tcp.send(socket, encoded("GET", stream_headers(id), ""))
    head = recv_until(socket, "\r\n\r\n", "")

    cond do
      head =~ "HTTP/1.1 200" ->
        socket

      attempts > 0 ->
        :gen_tcp.close(socket)
        reopen_stream(port, id, attempts - 1)

      true ->
        flunk("the standalone stream could not be opened again")
    end
  end

  defp encoded(method, headers, body) do
    headers = [
      {"Content-Length", Integer.to_string(byte_size(body))},
      {"Connection", "close"} | headers
    ]

    lines = Enum.map(headers, fn {name, value} -> [name, ": ", value, "\r\n"] end)
    [method, " /mcp HTTP/1.1\r\n", lines, "\r\n", body]
  end

  defp recv_all(socket, acc) do
    case :gen_tcp.recv(socket, 0, 2_000) do
      {:ok, chunk} -> recv_all(socket, acc <> chunk)
      {:error, :closed} -> acc
    end
  end

  defp recv_closed(socket) do
    case :gen_tcp.recv(socket, 0, 2_000) do
      {:ok, _chunk} -> recv_closed(socket)
      other -> other
    end
  end

  defp recv_until(socket, pattern, acc) do
    if String.contains?(acc, pattern) do
      acc
    else
      case :gen_tcp.recv(socket, 0, 2_000) do
        {:ok, chunk} -> recv_until(socket, pattern, acc <> chunk)
        {:error, reason} -> flunk("socket closed before #{inspect(pattern)}: #{inspect(reason)}")
      end
    end
  end

  # Returns the next SSE data event and the bytes after it. The buffer starts
  # with the response head, which is skipped.
  defp next_event(socket, buffer) do
    case Regex.run(~r/data: (.*?)\r\n\r\n/s, buffer, return: :index) do
      [{start, length}, {data_start, data_length}] ->
        data = binary_part(buffer, data_start, data_length)
        rest = binary_part(buffer, start + length, byte_size(buffer) - start - length)
        {JSON.decode!(data), rest}

      nil ->
        case :gen_tcp.recv(socket, 0, 2_000) do
          {:ok, chunk} -> next_event(socket, buffer <> chunk)
          {:error, reason} -> flunk("stream ended before the next event: #{inspect(reason)}")
        end
    end
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
end
