defmodule Snodo.LegacyStdioAcceptanceTest do
  use ExUnit.Case, async: true

  alias Snodo.Protocol.{V2025_06_18, V2025_11_25, V2026_07_28}
  alias Snodo.Transport.Stdio
  alias SnodoTest.TestFixtures
  alias SnodoTest.TestInput
  alias SnodoTest.TestTools.{Echo, Trapping}

  defmodule Progressing do
    use Snodo.Tool, name: "progressing"

    @impl true
    def call(_arguments, context) do
      :ok = Snodo.Progress.report(context, 1, total: 2, message: "halfway")
      {:ok, Snodo.Result.text("done")}
    end
  end

  defp runtime do
    TestFixtures.runtime(
      tools: [Echo, Trapping, Progressing],
      protocols: [V2026_07_28, V2025_11_25, V2025_06_18]
    )
  end

  for version <- ["2025-11-25", "2025-06-18"] do
    @version version

    test "#{version} negotiates over stdio and serves later requests in that dialect" do
      connection = connect(runtime())

      assert %{"result" => %{"protocolVersion" => @version, "serverInfo" => server_info}} =
               initialize(connection, @version)

      assert server_info["name"] == "snodo-spike"

      push(connection, request(2, "ping"))
      assert %{"result" => %{}} = await_response(connection, 2)

      push(connection, request(3, "tools/list"))
      assert %{"result" => %{"tools" => tools} = listed} = await_response(connection, 3)
      assert Enum.any?(tools, &(&1["name"] == "echo"))
      refute Map.has_key?(listed, "resultType")
      refute Map.has_key?(listed, "ttlMs")

      push(
        connection,
        request(4, "tools/call", %{"name" => "echo", "arguments" => %{"text" => "hello"}})
      )

      assert %{"result" => %{"content" => [%{"text" => "hello"}], "isError" => false} = called} =
               await_response(connection, 4)

      refute Map.has_key?(called, "resultType")

      # notifications/initialized gets no reply.
      assert Enum.map(finish(connection), & &1["id"]) == ["init", 2, 3, 4]
    end
  end

  test "an unsupported proposal negotiates the first legacy version, and initialize can repeat" do
    connection = connect(runtime())

    assert %{"result" => %{"protocolVersion" => "2025-11-25"}} =
             initialize(connection, "2024-11-05")

    push(connection, request(2, "tools/list"))
    assert %{"result" => %{"tools" => [_ | _]}} = await_response(connection, 2)

    assert %{"result" => %{"protocolVersion" => "2025-06-18"}} =
             initialize(connection, "2025-06-18")

    push(
      connection,
      request(3, "tools/call", %{"name" => "echo", "arguments" => %{"text" => "again"}})
    )

    assert %{"result" => %{"content" => [%{"text" => "again"}]}} = await_response(connection, 3)
    finish(connection)
  end

  test "a negotiated connection reports progress and honors cancellation" do
    token = Integer.to_string(System.unique_integer([:positive]))
    :yes = :global.register_name({Trapping, token}, self())
    on_exit(fn -> :global.unregister_name({Trapping, token}) end)

    connection = connect(runtime())
    initialize(connection, "2025-06-18")

    push(
      connection,
      request("progress", "tools/call", %{
        "name" => "progressing",
        "arguments" => %{},
        "_meta" => %{"progressToken" => "p1"}
      })
    )

    assert %{"result" => %{"content" => [%{"text" => "done"}]}} =
             await_response(connection, "progress")

    assert %{"params" => %{"progressToken" => "p1", "progress" => 1, "total" => 2}} =
             Enum.find(messages(connection), &(&1["method"] == "notifications/progress"))

    push(
      connection,
      request("cancel-me", "tools/call", %{
        "name" => "trapping",
        "arguments" => %{"token" => token}
      })
    )

    assert_receive {:trapping_entered, _worker, cancellation}, 1_000

    push(connection, %{
      "jsonrpc" => "2.0",
      "method" => "notifications/cancelled",
      "params" => %{"requestId" => "cancel-me", "reason" => "test"}
    })

    ids = connection |> finish() |> Enum.map(& &1["id"])
    assert Snodo.Cancellation.cancelled?(cancellation)
    refute "cancel-me" in ids
  end

  test "a 2026-07-28 client needs no initialize, and a bare request is not a legacy one" do
    connection = connect(runtime())

    push(
      connection,
      TestFixtures.request(1, "tools/call", %{
        "name" => "echo",
        "arguments" => %{"text" => "modern"}
      })
    )

    assert %{"result" => %{"resultType" => "complete", "content" => [%{"text" => "modern"}]}} =
             await_response(connection, 1)

    push(connection, request(2, "tools/list"))
    assert %{"error" => %{"code" => -32_602}} = await_response(connection, 2)
    finish(connection)
  end

  defp connect(runtime) do
    {:ok, input} = TestInput.start_link()
    {:ok, output} = StringIO.open("")
    server = Task.async(fn -> Stdio.serve(runtime, input: input, output: output) end)
    %{input: input, output: output, server: server}
  end

  defp request(id, method, params \\ %{}),
    do: %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}

  # A client sends notifications/initialized only after the initialize result.
  defp initialize(connection, version) do
    push(
      connection,
      request("init", "initialize", %{
        "protocolVersion" => version,
        "capabilities" => %{},
        "clientInfo" => %{"name" => "initialize-era", "version" => "1"}
      })
    )

    response = await_response(connection, "init", length(messages(connection)))
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

    raw_output
    |> String.split("\n", trim: true)
    |> Enum.map(&JSON.decode!/1)
  end

  # Waits for the newest response to `id`; `seen` skips responses already read,
  # since a repeated initialize reuses its id.
  defp await_response(connection, id, seen \\ 0, attempts \\ 100)

  defp await_response(connection, id, seen, attempts) when attempts > 0 do
    case connection |> messages() |> Enum.drop(seen) |> Enum.find(&(&1["id"] == id)) do
      nil ->
        Process.sleep(10)
        await_response(connection, id, seen, attempts - 1)

      response ->
        response
    end
  end

  defp await_response(_connection, id, _seen, 0),
    do: flunk("timed out waiting for the response to #{inspect(id)}")
end
