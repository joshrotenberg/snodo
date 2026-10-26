defmodule Snodo.LoggingTest do
  use ExUnit.Case, async: true

  alias Snodo.Client
  alias Snodo.Error
  alias Snodo.Protocol.{V2025_06_18, V2025_11_25, V2026_07_28}
  alias Snodo.Transport.Stdio
  alias Snodo.Transport.StreamableHTTP.Server, as: HTTPServer
  alias SnodoTest.TestInput

  @moduletag mcp_contract: ["server-logging"]

  @all_protocols [V2026_07_28, V2025_11_25, V2025_06_18]

  defmodule Server do
    use Snodo.Server,
      name: "logging-test",
      version: "1.0.0",
      capabilities: %{"tools" => %{}, "logging" => %{}}

    # Logs once at each level, then reports what each call returned.
    tool "levels", description: "Logs at every level" do
      @impl true
      def call(_arguments, context) do
        results =
          for level <- Snodo.Logging.levels() do
            Snodo.Logging.log(context, level, "#{level} message", logger: "levels")
          end

        {:ok, inspect(results)}
      end
    end

    tool "invalid", description: "Returns the result of each invalid call" do
      @impl true
      def call(_arguments, context) do
        results = [
          Snodo.Logging.log(context, :verbose, "x"),
          Snodo.Logging.log(context, "info", "x"),
          Snodo.Logging.log(context, :info, {:not, :json}),
          Snodo.Logging.log(context, :info, "x", logger: :atom),
          Snodo.Logging.log(context, :info, "x", unknown: true),
          Snodo.Logging.log(context, :info, String.duplicate("a", 16_384))
        ]

        {:ok, inspect(results)}
      end
    end

    tool "flood", description: "Logs until the request's limit" do
      @impl true
      def call(_arguments, context) do
        results = for n <- 1..1_001, do: Snodo.Logging.log(context, :info, n)
        {:ok, inspect({Enum.count(results, &(&1 == :ok)), List.last(results)})}
      end
    end

    tool "other_process", description: "Logs from a process that does not run the request" do
      @impl true
      def call(_arguments, context) do
        result = Task.async(fn -> Snodo.Logging.log(context, :error, "x") end) |> Task.await()
        {:ok, inspect(result)}
      end
    end

    tool "timed",
      description: "Logs from inside the timeout wrapper's task",
      wrap: [{Snodo.Component.Wrap.Timeout, timeout: 5_000}] do
      @impl true
      def call(_arguments, context) do
        {:ok, inspect(Snodo.Logging.log(context, :error, "from the task"))}
      end
    end

    tool "progress_and_log", description: "Interleaves progress and log messages" do
      @impl true
      def call(_arguments, context) do
        :ok = Snodo.Progress.report(context, 1, total: 2)
        :ok = Snodo.Logging.log(context, :info, "between")
        :ok = Snodo.Progress.report(context, 2, total: 2)
        {:ok, "done"}
      end
    end
  end

  defp text({:ok, %{"content" => [%{"text" => text}]}}), do: text

  defp direct(opts) do
    {protocols, opts} = Keyword.pop(opts, :protocols, @all_protocols)
    {runtime_opts, opts} = Keyword.pop(opts, :runtime, [])
    {:ok, client} = Client.direct(Server.runtime([protocols: protocols] ++ runtime_opts), opts)
    client
  end

  defp logged do
    receive do
      {:snodo_log, params} -> [params | logged()]
    after
      0 -> []
    end
  end

  describe "2026-07-28" do
    test "a request receives the messages at or above its level, in order" do
      client = direct(protocol: "2026-07-28", on_log: self(), log_level: :warning)
      assert text(Client.call_tool(client, "levels")) == inspect(List.duplicate(:ok, 8))

      assert [
               %{"level" => "warning", "data" => "warning message", "logger" => "levels"},
               %{"level" => "error"},
               %{"level" => "critical"},
               %{"level" => "alert"},
               %{"level" => "emergency"}
             ] = logged()

      assert {:ok, _result} = Client.call_tool(client, "levels", %{}, log_level: :debug)
      assert length(logged()) == 8
    end

    test "a request without a level receives no messages" do
      client = direct(protocol: "2026-07-28", on_log: self())
      assert text(Client.call_tool(client, "levels")) == inspect(List.duplicate(:ok, 8))
      assert logged() == []

      client = direct(protocol: "2026-07-28", on_log: self(), log_level: :info)
      assert {:ok, _result} = Client.call_tool(client, "levels", %{}, log_level: nil)
      assert logged() == []
    end

    test "a request's on_log replaces the client's" do
      parent = self()
      client = direct(protocol: "2026-07-28", on_log: self(), log_level: :emergency)

      assert {:ok, _result} =
               Client.call_tool(client, "levels", %{},
                 on_log: &send(parent, {:request_log, &1["level"]})
               )

      assert_received {:request_log, "emergency"}
      assert logged() == []

      assert {:ok, _result} = Client.call_tool(client, "levels", %{}, on_log: nil)
      refute_received {:request_log, _level}
      assert logged() == []

      client = direct(protocol: "2026-07-28", log_level: :emergency)
      assert {:ok, _result} = Client.call_tool(client, "levels", %{}, on_log: self())
      assert [%{"level" => "emergency"}] = logged()

      assert_raise ArgumentError, ~r/:on_log must be/, fn ->
        Client.call_tool(client, "levels", %{}, on_log: :nope)
      end
    end

    test "a runtime without the logging capability sends none, whatever the level" do
      runtime = [capabilities: %{"tools" => %{}}]
      client = direct(protocol: "2026-07-28", runtime: runtime, on_log: self())
      assert text(Client.call_tool(client, "levels")) == inspect(List.duplicate(:ok, 8))
      assert logged() == []

      client = direct(protocol: "2026-07-28", runtime: runtime, on_log: self(), log_level: :info)
      assert {:ok, _result} = Client.call_tool(client, "levels")
      assert logged() == []
    end

    test "an invalid logLevel is refused before the handler runs" do
      client = direct(protocol: "2026-07-28", on_log: self())

      assert {:error, %Error{code: -32_602}} =
               Client.call_tool(client, "levels", %{},
                 meta: %{"io.modelcontextprotocol/logLevel" => "verbose"}
               )

      assert logged() == []
    end

    test "progress and log messages share the request's channel in order" do
      parent = self()

      client =
        direct(
          protocol: "2026-07-28",
          log_level: :info,
          on_log: &send(parent, {:event, :log, &1["data"]})
        )

      assert {:ok, _result} =
               Client.call_tool(client, "progress_and_log", %{},
                 progress: &send(parent, {:event, :progress, &1["progress"]})
               )

      assert_received {:event, :progress, 1}
      assert_received {:event, :log, "between"}
      assert_received {:event, :progress, 2}
    end
  end

  describe "bounds and misuse" do
    setup do
      %{client: direct(protocol: "2026-07-28", on_log: self(), log_level: :debug)}
    end

    test "invalid input is an error and sends nothing", %{client: client} do
      expected = [
        {:error, :invalid_level},
        {:error, :invalid_level},
        {:error, :invalid_data},
        {:error, :invalid_logger},
        {:error, :invalid_logger},
        {:error, :too_large}
      ]

      assert text(Client.call_tool(client, "invalid")) == inspect(expected)
      assert logged() == []
    end

    test "a request may send at most 1,000 messages", %{client: client} do
      assert text(Client.call_tool(client, "flood")) == inspect({1_000, {:error, :limit_reached}})
      assert length(logged()) == 1_000
    end

    test "only the process that runs the request may log", %{client: client} do
      assert text(Client.call_tool(client, "other_process")) ==
               inspect({:error, :wrong_process})

      assert logged() == []
    end

    test "the timeout wrapper hands logging to its task", %{client: client} do
      assert text(Client.call_tool(client, "timed")) == inspect(:ok)
      assert [%{"data" => "from the task"}] = logged()
    end
  end

  describe "initialize-era dialects" do
    for version <- ["2025-11-25", "2025-06-18"] do
      @version version

      test "#{version} uses the runtime's level when the client has set none" do
        client = direct(protocol: @version, on_log: self())
        assert {:ok, _result} = Client.call_tool(client, "levels")
        assert [%{"level" => "info"} | rest] = logged()
        assert length(rest) == 6

        client = direct(protocol: @version, on_log: self(), runtime: [log_level: :critical])
        assert {:ok, _result} = Client.call_tool(client, "levels")
        assert Enum.map(logged(), & &1["level"]) == ["critical", "alert", "emergency"]
      end
    end

    test "logging/setLevel answers {} and validates the level" do
      client = direct(protocol: "2025-11-25")
      assert :ok = Client.set_log_level(client, :debug)

      assert {:error, %Error{code: -32_602}} =
               Client.request(client, "logging/setLevel", %{"level" => "verbose"})

      assert_raise ArgumentError, fn -> Client.set_log_level(client, :verbose) end
    end

    test "logging/setLevel needs the logging capability" do
      client = direct(protocol: "2025-11-25", runtime: [capabilities: %{"tools" => %{}}])
      assert {:error, %Error{code: -32_601}} = Client.set_log_level(client, :debug)
    end

    test "2026-07-28 does not define logging/setLevel" do
      client = direct(protocol: "2026-07-28")

      assert {:error, %Error{code: -32_601, kind: :protocol}} =
               Client.set_log_level(client, :info)
    end

    test "the logging capability is advertised at initialize" do
      client = direct(protocol: "2025-11-25")
      assert %{"logging" => %{}} = client.session.server_capabilities
    end
  end

  describe "Streamable HTTP" do
    test "a 2026-07-28 request streams its messages before the result" do
      url = http(Server.runtime())
      {:ok, client} = Client.connect({:http, url}, on_log: self(), log_level: :error)
      on_exit(fn -> Client.close(client) end)

      assert {:ok, _result} = Client.call_tool(client, "levels")
      assert Enum.map(logged(), & &1["level"]) == ["error", "critical", "alert", "emergency"]

      assert {:ok, _result} = Client.call_tool(client, "levels", %{}, log_level: nil)
      assert logged() == []
    end

    test "an initialize-era request uses the runtime's level" do
      url = http(Server.runtime(protocols: @all_protocols, log_level: :alert))

      {:ok, client} = Client.connect({:http, url}, protocol: "2025-11-25", on_log: self())
      on_exit(fn -> Client.close(client) end)

      assert {:ok, _result} = Client.call_tool(client, "levels")
      assert Enum.map(logged(), & &1["level"]) == ["alert", "emergency"]
    end

    defp http(runtime) do
      server = start_supervised!({HTTPServer, runtime: runtime, port: 0})
      HTTPServer.url(server)
    end
  end

  describe "stdio transport" do
    test "logging/setLevel holds for the connection, and initialize resets it" do
      connection = connect(Server.runtime(protocols: @all_protocols))
      initialize(connection, "2025-11-25")

      push(connection, request(1, "tools/call", %{"name" => "levels", "arguments" => %{}}))
      await_response(connection, 1)
      push(connection, request(2, "logging/setLevel", %{"level" => "alert"}))
      assert %{"result" => result} = await_response(connection, 2)
      assert result == %{}
      push(connection, request(3, "tools/call", %{"name" => "levels", "arguments" => %{}}))
      await_response(connection, 3)

      seen = length(messages(connection))
      initialize(connection, "2025-11-25", seen)
      push(connection, request(4, "tools/call", %{"name" => "levels", "arguments" => %{}}))
      await_response(connection, 4)

      levels =
        connection
        |> finish()
        |> Enum.flat_map(fn
          %{"method" => "notifications/message", "params" => %{"level" => level}} -> [level]
          %{"id" => id} when is_integer(id) -> [id]
          _other -> []
        end)

      info_and_above = ~w(info notice warning error critical alert emergency)

      assert levels ==
               info_and_above ++ [1, 2] ++ ~w(alert emergency) ++ [3] ++ info_and_above ++ [4]
    end

    defp connect(runtime) do
      {:ok, input} = TestInput.start_link()
      {:ok, output} = StringIO.open("")
      server = Task.async(fn -> Stdio.serve(runtime, input: input, output: output) end)
      %{input: input, output: output, server: server}
    end

    defp request(id, method, params),
      do: %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}

    defp initialize(connection, version, seen \\ 0) do
      push(
        connection,
        request("init", "initialize", %{
          "protocolVersion" => version,
          "capabilities" => %{},
          "clientInfo" => %{"name" => "logging-test", "version" => "1"}
        })
      )

      response = await_response(connection, "init", seen)
      push(connection, %{"jsonrpc" => "2.0", "method" => "notifications/initialized"})
      response
    end

    defp push(connection, message),
      do: TestInput.push(connection.input, JSON.encode!(message) <> "\n")

    defp finish(connection) do
      TestInput.eof(connection.input)
      assert :ok = Task.await(connection.server, 1_000)
      messages(connection)
    end

    defp messages(connection) do
      {_input, raw_output} = StringIO.contents(connection.output)
      raw_output |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)
    end

    defp await_response(connection, id, seen \\ 0, attempts \\ 200)

    defp await_response(connection, id, seen, attempts) when attempts > 0 do
      case connection |> messages() |> Enum.drop(seen) |> Enum.find(&(&1["id"] == id)) do
        nil ->
          Process.sleep(10)
          await_response(connection, id, seen, attempts - 1)

        response ->
          response
      end
    end
  end
end
