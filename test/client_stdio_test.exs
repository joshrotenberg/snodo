defmodule Snodo.ClientStdioTest do
  use ExUnit.Case, async: true

  alias Snodo.Client
  alias Snodo.Client.Session
  alias Snodo.Error

  @moduletag timeout: 30_000

  @fixture Path.expand("fixtures/client_stdio_server.exs", __DIR__)
  @initialize_era_fixture Path.expand("fixtures/client_initialize_era_server.exs", __DIR__)

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

  # The hand-written server needs nothing from snodo's build.
  defp initialize_era(opts, args \\ []) do
    elixir = System.find_executable("elixir")
    Client.connect({:stdio, elixir, [@initialize_era_fixture | args]}, opts)
  end

  test "lists and calls tools over a subprocess's stdin and stdout" do
    client = connect()
    assert %Client{protocol: "2026-07-28", session: nil} = client

    assert {:ok, %{"supportedVersions" => ["2026-07-28"]}} = Client.discover(client)
    assert {:ok, tools} = Client.list_tools(client)

    assert Enum.map(tools, & &1["name"]) |> Enum.sort() ==
             ~w(choice consent echo halt large park parked ticks)

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

  test "a server exit fails the request in flight and every later request" do
    client = connect()

    assert {:error, %Error{code: -32_000, kind: :transport, cause: {:exit_status, 3}}} =
             Client.call_tool(client, "halt")

    assert {:error, %Error{code: -32_000, cause: {:exit_status, 3}}} = Client.list_tools(client)
  end

  test "close/1 ends the connection" do
    client = connect()
    assert {:ok, _tools} = Client.list_tools(client)
    assert :ok = Client.close(client)
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

  test "an executable that does not exist is a transport error" do
    assert {:error, %Error{code: -32_000, kind: :transport, cause: :enoent}} =
             Client.connect({:stdio, "/nonexistent/mcp-server", []})

    assert {:error, %Error{code: -32_000}} =
             Client.connect({:stdio, "snodo-no-such-command-#{System.unique_integer()}", []})
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
