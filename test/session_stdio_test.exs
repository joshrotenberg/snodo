defmodule Snodo.SessionStdioTest do
  use ExUnit.Case, async: true

  alias Snodo.Protocol.{V2025_06_18, V2025_11_25, V2026_07_28}
  alias Snodo.Subscription.Hub
  alias Snodo.Transport.Stdio
  alias SnodoTest.TestFixtures
  alias SnodoTest.TestInput
  alias SnodoTest.TestTools.Echo

  defmodule Ask do
    @moduledoc false
    use Snodo.Tool, name: "ask"

    @impl true
    def call(_arguments, context) do
      request =
        Snodo.Elicitation.form("Name?", %{
          "type" => "object",
          "properties" => %{"name" => %{"type" => "string"}},
          "required" => ["name"]
        })

      case Snodo.Elicitation.response(context, "name", request) do
        :missing ->
          {:ok, Snodo.Result.input_required(input_requests: %{"name" => request})}

        {:ok, %{"content" => %{"name" => name}}} ->
          {:ok, Snodo.Result.text("Hello, #{name}")}
      end
    end
  end

  # An output device that forwards each written line to the test process, so
  # the test waits for messages instead of polling the output.
  defmodule Output do
    @moduledoc false

    def start_link(owner), do: {:ok, spawn_link(fn -> loop(owner, "") end)}

    defp loop(owner, buffer) do
      receive do
        {:io_request, from, reply_as, {:put_chars, _encoding, data}} ->
          send(from, {:io_reply, reply_as, :ok})
          loop(owner, emit(owner, buffer <> IO.iodata_to_binary(data)))

        {:io_request, from, reply_as, {:put_chars, _encoding, module, function, args}} ->
          send(from, {:io_reply, reply_as, :ok})
          data = apply(module, function, args)
          loop(owner, emit(owner, buffer <> IO.iodata_to_binary(data)))

        {:io_request, from, reply_as, _request} ->
          send(from, {:io_reply, reply_as, {:error, :enotsup}})
          loop(owner, buffer)
      end
    end

    defp emit(owner, buffer) do
      case :binary.split(buffer, "\n") do
        [line, rest] ->
          send(owner, {:stdout, JSON.decode!(line)})
          emit(owner, rest)

        [partial] ->
          partial
      end
    end
  end

  setup do
    hub = start_supervised!(Hub)

    runtime =
      TestFixtures.runtime(
        tools: [Echo, Ask],
        protocols: [V2026_07_28, V2025_11_25, V2025_06_18],
        capabilities: %{
          "tools" => %{"listChanged" => true},
          "resources" => %{"subscribe" => true}
        },
        resources: [SnodoTest.TestResources.StaticText],
        subscription_source: Hub.source(hub)
      )

    %{hub: hub, runtime: runtime}
  end

  test "the connection is the session: input requests travel on it", %{runtime: runtime} do
    connection = connect(runtime, sessions: true)

    assert %{"result" => %{"capabilities" => capabilities}} =
             initialize(connection, "2025-06-18", %{"elicitation" => %{}})

    assert capabilities["tools"] == %{"listChanged" => true}

    push(connection, request(2, "tools/call", %{"name" => "ask", "arguments" => %{}}))

    assert_receive {:stdout,
                    %{"id" => ask_id, "method" => "elicitation/create", "params" => params}}

    refute Map.has_key?(params, "mode")

    push(connection, %{
      "jsonrpc" => "2.0",
      "id" => ask_id,
      "result" => %{"action" => "accept", "content" => %{"name" => "Ada"}}
    })

    assert_receive {:stdout,
                    %{"id" => 2, "result" => %{"content" => [%{"text" => "Hello, Ada"}]}}}

    finish(connection)
  end

  test "resources/subscribe and list changes arrive on the connection", %{
    hub: hub,
    runtime: runtime
  } do
    connection = connect(runtime, sessions: true)
    initialize(connection, "2025-11-25")
    uri = "test://static"

    push(connection, request(2, "resources/subscribe", %{"uri" => uri}))
    assert_receive {:stdout, %{"id" => 2, "result" => result}}
    assert result == %{}

    {:ok, _report} = Hub.notify_resource_updated(hub, uri)

    assert_receive {:stdout,
                    %{"method" => "notifications/resources/updated", "params" => %{"uri" => ^uri}}}

    {:ok, _report} = Hub.notify_tools_list_changed(hub)
    assert_receive {:stdout, %{"method" => "notifications/tools/list_changed"}}
    finish(connection)
  end

  test "without sessions the dialects stay sessionless", %{runtime: runtime} do
    connection = connect(runtime, [])

    assert %{"result" => %{"capabilities" => capabilities}} =
             initialize(connection, "2025-11-25", %{"elicitation" => %{}})

    assert capabilities["tools"] == %{}

    push(connection, request(2, "resources/subscribe", %{"uri" => "test://static"}))
    assert_receive {:stdout, %{"id" => 2, "error" => %{"code" => -32_601}}}

    push(connection, request(3, "tools/call", %{"name" => "ask", "arguments" => %{}}))
    assert_receive {:stdout, %{"id" => 3, "error" => %{"code" => -32_603}}}
    finish(connection)
  end

  test "2026-07-28 messages on a session-enabled connection are unaffected", %{runtime: runtime} do
    connection = connect(runtime, sessions: true)

    push(
      connection,
      TestFixtures.request(1, "tools/call", %{"name" => "echo", "arguments" => %{"text" => "hi"}})
    )

    assert_receive {:stdout, %{"id" => 1, "result" => %{"resultType" => "complete"}}}
    finish(connection)
  end

  defp connect(runtime, opts) do
    {:ok, input} = TestInput.start_link()
    {:ok, output} = Output.start_link(self())

    server =
      Task.async(fn -> Stdio.serve(runtime, [input: input, output: output] ++ opts) end)

    %{input: input, server: server}
  end

  defp request(id, method, params),
    do: %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}

  defp initialize(connection, version, capabilities \\ %{}) do
    push(
      connection,
      request("init", "initialize", %{
        "protocolVersion" => version,
        "capabilities" => capabilities,
        "clientInfo" => %{"name" => "session-test", "version" => "1"}
      })
    )

    assert_receive {:stdout, %{"id" => "init"} = response}
    push(connection, %{"jsonrpc" => "2.0", "method" => "notifications/initialized"})
    response
  end

  defp push(connection, message),
    do: TestInput.push(connection.input, JSON.encode!(message) <> "\n")

  defp finish(connection) do
    TestInput.eof(connection.input)
    assert :ok = Task.await(connection.server, 1_000)
  end
end
