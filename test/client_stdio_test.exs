defmodule Snodo.ClientStdioTest do
  use ExUnit.Case, async: true

  alias Snodo.Client
  alias Snodo.Client.Session
  alias Snodo.Client.Subscription
  alias Snodo.Error

  @moduletag timeout: 30_000

  @fixture Path.expand("fixtures/client_stdio_server.exs", __DIR__)
  @initialize_era_fixture Path.expand("fixtures/client_initialize_era_server.exs", __DIR__)
  @server_requests_fixture Path.expand("fixtures/client_server_requests.exs", __DIR__)

  defp connect(opts \\ [], args \\ []) do
    {:ok, client} = start_client(opts, args)
    on_exit(fn -> Client.close(client) end)
    client
  end

  defp start_client(opts, args \\ []) do
    elixir = System.find_executable("elixir")
    ebin = Path.expand(Mix.Project.compile_path())
    Client.connect({:stdio, elixir, ["-pa", ebin, @fixture | args]}, opts)
  end

  # The hand-written servers need nothing from snodo's build.
  defp initialize_era(opts, args \\ []) do
    elixir = System.find_executable("elixir")
    Client.connect({:stdio, elixir, [@initialize_era_fixture | args]}, opts)
  end

  # Pinned to 2026-07-28, so nothing is sent at connect time.
  defp server_requests(opts, args) do
    elixir = System.find_executable("elixir")
    opts = Keyword.put(opts, :protocol, "2026-07-28")
    Client.connect({:stdio, elixir, [@server_requests_fixture | args]}, opts)
  end

  # A form handler that reports its pid and waits to be released.
  defp blocking_form(test) do
    fn _params ->
      send(test, {:handler, self()})

      receive do
        :release -> {:ok, %{"action" => "accept", "content" => %{"name" => "Ada"}}}
      end
    end
  end

  test "lists and calls tools over a subprocess's stdin and stdout" do
    client = connect()
    assert %Client{protocol: "2026-07-28", session: nil} = client

    assert {:ok, %{"supportedVersions" => ["2026-07-28"]}} = Client.discover(client)
    assert {:ok, tools} = Client.list_tools(client)

    assert Enum.map(tools, & &1["name"]) |> Enum.sort() ==
             ~w(choice complete consent echo emit fail halt large mixed park parked roots sample subscriptions ticks)

    assert {:ok, %{"content" => [%{"text" => "over stdio"}]}} =
             Client.call_tool(client, "echo", %{"text" => "over stdio"})

    assert {:error, %Error{code: -32_602, kind: :protocol}} =
             Client.call_tool(client, "no_such_tool")
  end

  test "non-ASCII text round-trips through a subprocess under any locale" do
    text = "héllo 日本 😀 line\u2028separator"

    for locale <- ["en_US.UTF-8", "C"] do
      client = connect(env: [{"LANG", locale}, {"LC_ALL", locale}])

      assert {:ok, %{"content" => [%{"text" => ^text}]}} =
               Client.call_tool(client, "echo", %{"text" => text})
    end
  end

  test "a response over :max_line_bytes is discarded and later responses still arrive" do
    client = connect(max_line_bytes: 100_000)

    assert {:error, %Error{code: -32_001}} =
             Client.call_tool(client, "large", %{"bytes" => 300_000}, timeout: 1_000)

    assert {:ok, %{"content" => [%{"text" => "still here"}]}} =
             Client.call_tool(client, "echo", %{"text" => "still here"})

    assert {:ok, %{"content" => [%{"text" => text}]}} =
             Client.call_tool(client, "large", %{"bytes" => 50_000})

    assert byte_size(text) == 50_000
  end

  test ":max_line_bytes must be a positive integer" do
    assert_raise ArgumentError, ~r/:max_line_bytes/, fn ->
      Client.connect({:stdio, System.find_executable("elixir"), []}, max_line_bytes: 0)
    end
  end

  test "correlates concurrent requests that complete out of order" do
    client = connect()

    results =
      [300, 0, 150, 50]
      |> Task.async_stream(
        fn delay ->
          Client.call_tool(client, "echo", %{"text" => "#{delay}", "delayMs" => delay})
        end,
        ordered: true
      )
      |> Enum.map(fn {:ok, {:ok, result}} -> hd(result["content"])["text"] end)

    assert results == ["300", "0", "150", "50"]
  end

  test "reassembles a response line longer than the port's line buffer" do
    client = connect()

    assert {:ok, %{"content" => [%{"text" => text}]}} =
             Client.call_tool(client, "large", %{"bytes" => 200_000})

    assert byte_size(text) == 200_000
  end

  test "a timeout returns -32001 and cancels the request on the server" do
    client = connect()

    assert {:error, %Error{code: -32_001, kind: :transport, data: %{"timeoutMs" => 200}}} =
             Client.call_tool(client, "park", %{}, timeout: 200)

    assert eventually(fn ->
             {:ok, %{"structuredContent" => %{"alive" => alive}}} =
               Client.call_tool(client, "parked")

             alive == 0
           end)

    assert {:ok, _result} = Client.call_tool(client, "echo", %{"text" => "still serving"})
  end

  describe "progress" do
    test "notifications reach the progress function in order before the result" do
      client = connect()

      assert {:ok, %{"content" => [%{"text" => "ticked 3"}]}} =
               Client.call_tool(client, "ticks", %{"count" => 3}, progress: self())

      assert [
               %{"progress" => 1, "total" => 3, "message" => "tick 1"},
               %{"progress" => 2},
               %{"progress" => 3}
             ] = drain_progress()
    end

    test "reset_timeout_on_progress keeps a request alive up to max_total_timeout" do
      client = connect()
      # The first request also waits for the server VM to boot.
      assert {:ok, _result} = Client.discover(client)
      arguments = %{"count" => 25, "intervalMs" => 100}

      assert {:error, %Error{code: -32_001, data: %{"timeoutMs" => 2_000}}} =
               Client.call_tool(client, "ticks", arguments, progress: self(), timeout: 2_000)

      assert {:ok, %{"content" => [%{"text" => "ticked 25"}]}} =
               Client.call_tool(client, "ticks", arguments,
                 progress: self(),
                 timeout: 2_000,
                 reset_timeout_on_progress: true
               )

      assert {:error,
              %Error{
                code: -32_001,
                message: "Maximum total timeout exceeded",
                data: %{"maxTotalTimeoutMs" => 2_200}
              }} =
               Client.call_tool(client, "ticks", arguments,
                 progress: self(),
                 timeout: 2_000,
                 reset_timeout_on_progress: true,
                 max_total_timeout: 2_200
               )
    end

    test "a progress function that raises abandons the request and the connection keeps serving" do
      client = connect()

      assert_raise RuntimeError, "stop", fn ->
        Client.call_tool(client, "ticks", %{"count" => 50, "intervalMs" => 20},
          progress: fn _params -> raise "stop" end
        )
      end

      assert {:ok, _result} = Client.call_tool(client, "echo", %{"text" => "still serving"})
    end
  end

  test "input handlers answer form and URL requests over stdio" do
    handlers = %{
      form: fn %{"mode" => "form"} ->
        {:ok, %{"action" => "accept", "content" => %{"label" => "stdio"}}}
      end,
      url: fn %{"mode" => "url"} -> {:ok, %{"action" => "accept"}} end
    }

    client = connect(input_handlers: handlers)

    assert {:ok, %{"structuredContent" => %{"label" => "stdio"}}} =
             Client.call_tool(client, "choice")

    assert {:ok, %{"structuredContent" => %{"action" => "accept"}}} =
             Client.call_tool(client, "consent")

    assert {:input_required, %{"inputRequests" => %{"choice" => _request}}} =
             Client.call_tool(client, "choice", %{}, answer_input: false)
  end

  test "input handlers answer sampling and roots requests over stdio" do
    sampled = %{
      "role" => "assistant",
      "content" => %{"type" => "text", "text" => "stdio"},
      "model" => "test-model"
    }

    roots = %{"roots" => [%{"uri" => "file:///stdio"}]}

    handlers = %{
      form: fn %{"mode" => "form"} ->
        {:ok, %{"action" => "accept", "content" => %{"label" => "stdio"}}}
      end,
      sampling: fn %{"messages" => [_message], "maxTokens" => 64} -> {:ok, sampled} end,
      roots: fn params when params == %{} -> {:ok, roots} end
    }

    client = connect(input_handlers: handlers)

    assert {:ok, %{"structuredContent" => %{"summary" => "stdio", "model" => "test-model"}}} =
             Client.call_tool(client, "sample")

    assert {:ok, %{"structuredContent" => %{"uris" => ["file:///stdio"]}}} =
             Client.call_tool(client, "roots")

    # One round asks for all three kinds.
    assert {:ok, %{"structuredContent" => answers}} = Client.call_tool(client, "mixed")

    assert answers == %{
             "choice" => %{"action" => "accept", "content" => %{"label" => "stdio"}},
             "summary" => sampled,
             "client_roots" => roots
           }

    # An invalid result is refused before anything is sent.
    client =
      connect(
        input_handlers: %{
          sampling: fn _params ->
            {:ok, %{"role" => "assistant", "content" => [], "model" => "m"}}
          end
        }
      )

    assert {:error,
            %Error{
              code: -32_603,
              kind: :execution,
              cause: {:input_handler, "summary", {:invalid_response, _response}, _last}
            }} = Client.call_tool(client, "sample")
  end

  test "a server exit fails the request in flight and every later request" do
    client = connect()

    assert {:error, %Error{code: -32_000, kind: :transport, cause: {:exit_status, 3}}} =
             Client.call_tool(client, "halt")

    assert {:error, %Error{code: -32_000, cause: {:exit_status, 3}}} = Client.list_tools(client)
  end

  # The server closes stdin before sending an elicitation. Depending on pipe
  # ownership, the pending write fails with EPIPE or when the shell exits.
  test "a server that closes stdin fails an in-flight request" do
    elicitation =
      JSON.encode!(%{
        "jsonrpc" => "2.0",
        "id" => "srv-1",
        "method" => "elicitation/create",
        "params" => %{
          "mode" => "form",
          "message" => "Your name?",
          "requestedSchema" => %{"type" => "object", "properties" => %{}}
        }
      })

    script = "exec 0<&-; printf '%s\\n' \"$1\"; sleep 5"

    {:ok, client} =
      Client.connect({:stdio, "/bin/sh", ["-c", script, "sh", elicitation]},
        protocol: "2026-07-28",
        timeout: 10_000,
        input_handlers: %{form: blocking_form(self())}
      )

    on_exit(fn -> Client.close(client) end)
    assert_receive {:handler, _handler}, 5_000

    assert {:error, %Error{code: -32_000, kind: :transport, cause: cause}} =
             Client.list_tools(client)

    assert cause in [{:port_exit, :epipe}, {:exit_status, 0}]

    assert {:error, %Error{code: -32_000, cause: ^cause}} =
             Client.list_tools(client)
  end

  test "close/1 ends the connection" do
    client = connect()
    assert {:ok, _tools} = Client.list_tools(client)
    assert :ok = Client.close(client)
    assert {:error, %Error{code: -32_000, kind: :transport}} = Client.list_tools(client)
  end

  test "an exit signal from another process stops the connection" do
    client = connect()
    %Client{transport: {Snodo.Client.Stdio, connection}} = client
    monitor = Process.monitor(connection)

    Process.exit(connection, :normal)
    assert {:ok, _tools} = Client.list_tools(client)

    Process.exit(connection, :shutdown)
    assert_receive {:DOWN, ^monitor, :process, ^connection, :shutdown}, 5_000
    assert {:error, %Error{code: -32_000, kind: :transport}} = Client.list_tools(client)
  end

  test "the connection closes when the process that opened it exits" do
    parent = self()

    {pid, ref} =
      spawn_monitor(fn ->
        {:ok, client} = start_client([])
        send(parent, {:client, client})
      end)

    assert_receive {:client, %Client{transport: {Snodo.Client.Stdio, connection}}}, 10_000
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    connection_ref = Process.monitor(connection)
    assert_receive {:DOWN, ^connection_ref, :process, ^connection, _reason}, 5_000
  end

  describe "initialize-era servers" do
    test "a snodo server with only the legacy dialects is initialized after the probe fails" do
      client = connect([], ["--initialize-era"])

      assert %Client{protocol: "2025-11-25", session: %Session{id: nil} = session} = client
      assert session.server_info == %{"name" => "client-stdio-fixture", "version" => "0.1.0"}
      assert session.server_capabilities == %{"tools" => %{}}

      assert {:ok, tools} = Client.list_tools(client)
      assert Enum.any?(tools, &(&1["name"] == "echo"))

      assert {:ok, %{"content" => [%{"text" => "legacy stdio"}]} = result} =
               Client.call_tool(client, "echo", %{"text" => "legacy stdio"})

      refute Map.has_key?(result, "resultType")
      assert {:ok, %{}} = Client.ping(client)
      assert {:error, %Error{code: -32_601}} = Client.discover(client)

      assert {:ok, %{"content" => [%{"text" => "ticked 2"}]}} =
               Client.call_tool(client, "ticks", %{"count" => 2}, progress: self())

      assert [%{"progress" => 1}, %{"progress" => 2}] = drain_progress()

      # A pin sends initialize without a probe.
      client = connect([protocol: "2025-06-18"], ["--initialize-era"])
      assert %Client{protocol: "2025-06-18", session: %Session{version: "2025-06-18"}} = client
      assert {:ok, _tools} = Client.list_tools(client)
    end

    test "the server is started again before initialize, because the probe reached it" do
      {:ok, client} = initialize_era([])
      on_exit(fn -> Client.close(client) end)

      assert %Client{protocol: "2025-11-25", session: %Session{} = session} = client
      assert session.instructions == "A hand-written 2025-11-25 server."

      # This process saw initialize and this call: the probe went to the one
      # before it.
      assert {:ok, %{"content" => [%{"text" => "2"}]}} = Client.call_tool(client, "requests_seen")

      for discover <- ["garbage", "silent"] do
        {:ok, client} = initialize_era([probe_timeout: 500], ["--discover", discover])
        assert %Client{protocol: "2025-11-25"} = client

        assert {:ok, %{"content" => [%{"text" => "2"}]}} =
                 Client.call_tool(client, "requests_seen")

        assert :ok = Client.close(client)
      end

      # A pinned version needs no probe, so the first process serves.
      {:ok, client} = initialize_era(protocol: "2025-06-18")
      assert %Client{protocol: "2025-06-18"} = client
      assert {:ok, %{"content" => [%{"text" => "2"}]}} = Client.call_tool(client, "requests_seen")
      assert :ok = Client.close(client)
    end

    test "a version the server picks outside the allowed list ends the connection" do
      assert {:error,
              %Error{
                code: -32_602,
                data: %{"negotiated" => "2025-06-18", "requested" => ["2025-11-25"]}
              }} = initialize_era([protocol: "2025-11-25"], ["--serve", "2025-06-18"])

      assert {:ok, %Client{protocol: "2025-06-18"} = client} =
               initialize_era([protocol: ["2025-11-25", "2025-06-18"]], ["--serve", "2025-06-18"])

      assert :ok = Client.close(client)
    end

    test "the server's own requests are answered by the installed handlers" do
      test = self()

      form = fn params ->
        send(test, {:asked, params})
        {:ok, %{"action" => "accept", "content" => %{"name" => "Ada"}}}
      end

      for version <- ["2025-11-25", "2025-06-18"] do
        {:ok, client} = initialize_era(input_handlers: %{form: form}, protocol: version)

        assert {:ok, %{"content" => [%{"text" => "hello Ada"}]}} = Client.call_tool(client, "ask")
        assert_receive {:asked, %{"message" => "Your name?"} = params}, 1_000
        assert Map.has_key?(params, "mode") == (version == "2025-11-25")

        # A server ping needs no handler.
        assert {:ok, %{"content" => [%{"text" => "pong"}]}} = Client.call_tool(client, "ping_me")
        assert :ok = Client.close(client)
      end

      # Without a handler the server is told -32601 and the connection keeps
      # serving; a handler that raises is told -32603.
      {:ok, client} = initialize_era(protocol: "2025-11-25")

      assert {:ok, %{"isError" => true, "content" => [%{"text" => text}]}} =
               Client.call_tool(client, "ask")

      assert text =~ "elicitation failed: -32601"
      assert {:ok, %{"content" => [%{"text" => "pong"}]}} = Client.call_tool(client, "ping_me")
      assert :ok = Client.close(client)

      raising = fn _params -> raise "no answer" end
      {:ok, client} = initialize_era(input_handlers: %{form: raising}, protocol: "2025-11-25")

      assert {:ok, %{"isError" => true, "content" => [%{"text" => text}]}} =
               Client.call_tool(client, "ask")

      assert text =~ "elicitation failed: -32603"

      assert {:ok, %{"content" => [%{"text" => "still here"}]}} =
               Client.call_tool(client, "echo", %{"text" => "still here"})

      assert :ok = Client.close(client)
    end
  end

  describe "server-to-client requests" do
    test "a 2026-07-28 connection answers them through the installed handlers too" do
      form = fn _params -> {:ok, %{"action" => "accept", "content" => %{"name" => "Ada"}}} end
      {:ok, client} = server_requests([input_handlers: %{form: form}], [])
      on_exit(fn -> Client.close(client) end)

      assert %Client{protocol: "2026-07-28", session: nil} = client
      assert {:ok, %{"answers" => answers}} = Client.request(client, "tools/list")
      assert %{"result" => %{}} = answers["srv-ping"]
      assert %{"result" => %{"action" => "accept"}} = answers["srv-1"]
    end

    test "handlers still running when the client closes are stopped" do
      test = self()

      {:ok, client} =
        server_requests([input_handlers: %{form: blocking_form(test)}], ["--elicit", "2"])

      assert_receive {:handler, first}, 10_000
      assert_receive {:handler, second}, 5_000
      refs = Enum.map([first, second], &Process.monitor/1)

      assert :ok = Client.close(client)

      for ref <- refs do
        assert_receive {:DOWN, ^ref, :process, _pid, :killed}, 5_000
      end
    end

    test "handlers still running when the owner exits are stopped" do
      test = self()

      {owner, owner_ref} =
        spawn_monitor(fn ->
          {:ok, client} = server_requests([input_handlers: %{form: blocking_form(test)}], [])
          send(test, {:client, client})
          receive do: (:exit -> :ok)
        end)

      assert_receive {:client, %Client{transport: {Snodo.Client.Stdio, connection}}}, 10_000
      assert_receive {:handler, handler}, 10_000
      handler_ref = Process.monitor(handler)
      connection_ref = Process.monitor(connection)

      send(owner, :exit)
      assert_receive {:DOWN, ^owner_ref, :process, ^owner, :normal}, 5_000
      assert_receive {:DOWN, ^connection_ref, :process, ^connection, :normal}, 5_000
      assert_receive {:DOWN, ^handler_ref, :process, ^handler, :killed}, 5_000
    end

    test "a handler killed from outside is answered -32603" do
      {:ok, client} = server_requests([input_handlers: %{form: blocking_form(self())}], [])
      on_exit(fn -> Client.close(client) end)

      assert_receive {:handler, handler}, 10_000
      Process.exit(handler, :kill)

      assert {:ok, %{"answers" => answers}} = Client.request(client, "tools/list")
      assert %{"error" => %{"code" => -32_603, "message" => message}} = answers["srv-1"]
      assert message =~ "exited: :killed"
    end

    test "a request over :max_server_requests is answered -32603 without a handler" do
      test = self()
      handlers = %{form: blocking_form(test)}

      {:ok, client} =
        server_requests(
          [input_handlers: handlers, max_server_requests: 2],
          ["--elicit", "3", "--no-ping"]
        )

      on_exit(fn -> Client.close(client) end)

      # The first two block, so the only answer the server can get is the
      # refusal of the third.
      assert_receive {:handler, first}, 10_000
      assert_receive {:handler, second}, 5_000

      assert {:ok, %{"answers" => answers}} =
               Client.request(client, "tools/list", %{"waitFor" => 1})

      assert [{"srv-3", %{"error" => error}}] = Map.to_list(answers)
      assert %{"code" => -32_603, "message" => "Too many server requests in flight (2)"} = error
      refute_received {:handler, _third}

      send(first, :release)
      send(second, :release)

      assert {:ok, %{"answers" => answers}} = Client.request(client, "tools/list")
      assert %{"result" => %{"action" => "accept"}} = answers["srv-1"]
      assert %{"result" => %{"action" => "accept"}} = answers["srv-2"]

      assert_raise ArgumentError, ~r/:max_server_requests/, fn ->
        server_requests([max_server_requests: 0], [])
      end
    end
  end

  test "an executable that does not exist is a transport error" do
    assert {:error, %Error{code: -32_000, kind: :transport, cause: :enoent}} =
             Client.connect({:stdio, "/nonexistent/mcp-server", []})

    assert {:error, %Error{code: -32_000}} =
             Client.connect({:stdio, "snodo-no-such-command-#{System.unique_integer()}", []})
  end

  describe "subscriptions" do
    @tools_filter %{"toolsListChanged" => true}

    test "listen/3 returns the accepted filter and delivers events on demand" do
      client = connect()

      requested = %{
        "toolsListChanged" => true,
        "promptsListChanged" => true,
        "resourceSubscriptions" => ["test://resource/one"]
      }

      assert {:ok, %Subscription{accepted: accepted, ref: ref} = subscription} =
               Client.listen(client, requested)

      assert accepted == Map.delete(requested, "promptsListChanged")
      assert subscription.owner == self()

      assert {:ok, %{"structuredContent" => %{"open" => 1}}} =
               Client.call_tool(client, "subscriptions")

      :ok = Subscription.demand(subscription, 2)
      emit(client, %{"kind" => "resource", "uri" => "test://resource/one"})
      emit(client, %{"kind" => "tools", "seq" => 1})
      emit(client, %{"kind" => "tools", "seq" => 2})

      assert_receive {:snodo_subscription, ^ref,
                      {:notification, "notifications/resources/updated", updated}},
                     5_000

      assert updated["uri"] == "test://resource/one"
      assert updated["_meta"]["io.modelcontextprotocol/subscriptionId"] == subscription.id

      assert_receive {:snodo_subscription, ^ref,
                      {:notification, "notifications/tools/list_changed", first}},
                     5_000

      assert first["_meta"]["seq"] == 1
      refute_receive {:snodo_subscription, ^ref, _payload}, 100

      assert {:notification, "notifications/tools/list_changed", %{"_meta" => %{"seq" => 2}}} =
               Subscription.next(subscription, 5_000)

      # Ordinary requests keep flowing on the shared connection.
      assert {:ok, %{"content" => [%{"text" => "still serving"}]}} =
               Client.call_tool(client, "echo", %{"text" => "still serving"})
    end

    test "a full buffer drops the oldest event and reports the count" do
      client = connect()
      {:ok, subscription} = Client.listen(client, @tools_filter, max_buffer: 2)
      %{ref: ref, pid: connection, id: id} = subscription

      for sequence <- 1..3, do: emit(client, %{"kind" => "tools", "seq" => sequence})

      assert eventually(fn ->
               entry = :sys.get_state(connection).subscriptions[id]
               entry.buffer.size == 2 and entry.buffer.dropped == 1
             end)

      :ok = Subscription.demand(subscription, 10)
      assert_receive {:snodo_subscription, ^ref, {:dropped, 1}}, 5_000
      assert_receive {:snodo_subscription, ^ref, {:notification, _method, second}}, 5_000
      assert second["_meta"]["seq"] == 2
      assert_receive {:snodo_subscription, ^ref, {:notification, _method, third}}, 5_000
      assert third["_meta"]["seq"] == 3
      refute_received {:snodo_subscription, ^ref, _other}
    end

    test "close/1 cancels the stream on the server and drops the connection's entry" do
      client = connect()
      {:ok, subscription} = Client.listen(client, @tools_filter)
      %{pid: connection, id: id} = subscription

      assert Map.has_key?(:sys.get_state(connection).subscriptions, id)
      assert :ok = Subscription.close(subscription)
      assert :sys.get_state(connection).subscriptions == %{}
      assert :sys.get_state(connection).subscription_refs == %{}
      assert :sys.get_state(connection).subscription_owners == %{}
      assert eventually(fn -> open_subscriptions(client) == 0 end)
      assert :ok = Subscription.close(subscription)
    end

    test "the owner's exit cancels the stream" do
      client = connect()
      test = self()

      owner =
        spawn(fn ->
          {:ok, subscription} = Client.listen(client, @tools_filter)
          send(test, {:listening, subscription})
          Process.sleep(:infinity)
        end)

      assert_receive {:listening, %Subscription{pid: connection}}, 10_000
      Process.exit(owner, :kill)

      assert eventually(fn -> :sys.get_state(connection).subscriptions == %{} end)
      assert eventually(fn -> open_subscriptions(client) == 0 end)
    end

    test "the server's terminal result follows the queued events" do
      client = connect()
      {:ok, subscription} = Client.listen(client, @tools_filter)
      %{ref: ref, pid: connection, id: id} = subscription

      emit(client, %{"kind" => "tools", "seq" => 1})
      emit(client, %{"kind" => "tools", "seq" => 2})
      assert {:ok, _result} = Client.call_tool(client, "complete")
      assert eventually(fn -> open_subscriptions(client) == 0 end)

      assert {:notification, _method, %{"_meta" => %{"seq" => 1}}} =
               Subscription.next(subscription, 5_000)

      refute_receive {:snodo_subscription, ^ref, _payload}, 50

      assert {:notification, _method, %{"_meta" => %{"seq" => 2}}} =
               Subscription.next(subscription, 5_000)

      assert_receive {:snodo_subscription, ^ref, {:closed, :complete}}, 5_000
      refute Map.has_key?(:sys.get_state(connection).subscriptions, id)
    end

    test "next/2 on a stream that has ended returns at once, as over the other transports" do
      client = connect()
      {:ok, subscription} = Client.listen(client, @tools_filter)
      %{pid: connection} = subscription

      # The terminal message needs no demand, so it is already in the
      # mailbox when next/2 asks; the connection's answer to that call is
      # not left behind.
      assert {:ok, _result} = Client.call_tool(client, "complete")
      assert eventually(fn -> :sys.get_state(connection).subscriptions == %{} end)
      assert {:closed, :complete} = Subscription.next(subscription, 5_000)
      refute_receive _stray, 200

      assert {:closed, {:error, %Error{code: -32_000, message: "The subscription has ended"}}} =
               Subscription.next(subscription, 1_000)

      {:ok, %Subscription{ref: ref} = subscription} = Client.listen(client, @tools_filter)
      assert :ok = Subscription.close(subscription)

      assert {:closed, {:error, %Error{code: -32_000, message: "The subscription has ended"}}} =
               Subscription.next(subscription, 1_000)

      refute_receive {:snodo_subscription, ^ref, _payload}, 100
    end

    # The server reads the listen request, closes stdin, and acknowledges.
    # The next write may fail with EPIPE or when the shell exits.
    test "a closed stdin ends open streams with a transport error" do
      acknowledgement =
        %{
          "jsonrpc" => "2.0",
          "method" => "notifications/subscriptions/acknowledged",
          "params" => %{
            "notifications" => @tools_filter,
            "_meta" => %{"io.modelcontextprotocol/subscriptionId" => "ID"}
          }
        }
        |> JSON.encode!()
        |> String.replace(~s("ID"), "%s")

      script = """
      read -r line
      id=$(printf '%s' "$line" | sed 's/.*"id":\\([0-9]*\\).*/\\1/')
      exec 0<&-
      printf "$1\\n" "$id"
      sleep 5
      """

      {:ok, client} =
        Client.connect({:stdio, "/bin/sh", ["-c", script, "sh", acknowledgement]},
          protocol: "2026-07-28",
          timeout: 10_000
        )

      on_exit(fn -> Client.close(client) end)
      {:ok, subscription} = Client.listen(client, @tools_filter)

      assert {:error, %Error{code: -32_000, cause: cause}} =
               Client.list_tools(client)

      assert cause in [{:port_exit, :epipe}, {:exit_status, 0}]

      assert {:closed, {:error, %Error{code: -32_000, kind: :transport} = error}} =
               Subscription.next(subscription, 5_000)

      assert error.cause == cause
    end

    test "a source failure ends the stream with the server's error" do
      client = connect()
      {:ok, subscription} = Client.listen(client, @tools_filter)

      assert {:ok, _result} = Client.call_tool(client, "fail")

      assert {:closed, {:error, %Error{code: -32_603, kind: :execution}}} =
               Subscription.next(subscription, 5_000)
    end

    test "malformed demand and next messages do not stop the connection" do
      client = connect()
      {:ok, %Subscription{ref: ref, pid: connection}} = Client.listen(client, @tools_filter)
      monitor = Process.monitor(connection)

      send(connection, {:mcp_client_demand, ref, 0})
      send(connection, {:mcp_client_demand, ref, :many})
      send(connection, {:mcp_client_next, make_ref(), self()})
      send(connection, {:mcp_client_next, make_ref(), :nobody})

      assert {:ok, _tools} = Client.list_tools(client)
      refute_received {:DOWN, ^monitor, :process, ^connection, _reason}
    end

    test "an error response is returned instead of a handle" do
      client = connect()

      assert {:error, %Error{code: -32_602, kind: :protocol}} =
               Client.listen(client, %{"toolsListChanged" => "yes"})

      assert :sys.get_state(elem(client.transport, 1)).subscriptions == %{}
    end

    test "the server's exit and close/1 end open streams with a transport error" do
      client = connect()
      {:ok, subscription} = Client.listen(client, @tools_filter)
      assert {:error, %Error{code: -32_000}} = Client.call_tool(client, "halt")

      assert {:closed, {:error, %Error{code: -32_000, cause: {:exit_status, 3}}}} =
               Subscription.next(subscription, 5_000)

      client = connect()
      {:ok, subscription} = Client.listen(client, @tools_filter)
      assert :ok = Client.close(client)

      assert {:closed, {:error, %Error{code: -32_000, kind: :transport}}} =
               Subscription.next(subscription, 5_000)
    end
  end

  defp emit(client, arguments) do
    assert {:ok, %{"content" => [%{"text" => "emitted"}]}} =
             Client.call_tool(client, "emit", arguments)
  end

  defp open_subscriptions(client) do
    {:ok, %{"structuredContent" => %{"open" => open}}} = Client.call_tool(client, "subscriptions")
    open
  end

  defp drain_progress do
    receive do
      {:snodo_progress, params} -> [params | drain_progress()]
    after
      0 -> []
    end
  end

  defp eventually(check, attempts \\ 50) do
    Enum.any?(1..attempts, fn _attempt ->
      check.() || (Process.sleep(20) && false)
    end)
  end
end
