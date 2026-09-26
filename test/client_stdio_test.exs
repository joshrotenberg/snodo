defmodule Snodo.ClientStdioTest do
  use ExUnit.Case, async: true

  alias Snodo.Client
  alias Snodo.Error

  @moduletag timeout: 30_000

  @fixture Path.expand("fixtures/client_stdio_server.exs", __DIR__)

  defp connect(opts \\ []) do
    {:ok, client} = start_client(opts)
    on_exit(fn -> Client.close(client) end)
    client
  end

  defp start_client(opts) do
    elixir = System.find_executable("elixir")
    ebin = Path.expand(Mix.Project.compile_path())
    Client.connect({:stdio, elixir, ["-pa", ebin, @fixture]}, opts)
  end

  test "lists and calls tools over a subprocess's stdin and stdout" do
    client = connect()

    assert {:ok, %{"supportedVersions" => ["2026-07-28"]}} = Client.discover(client)
    assert {:ok, tools} = Client.list_tools(client)
    assert Enum.map(tools, & &1["name"]) |> Enum.sort() == ~w(echo halt large park parked)

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

  test "an executable that does not exist is a transport error" do
    assert {:error, %Error{code: -32_000, kind: :transport, cause: :enoent}} =
             Client.connect({:stdio, "/nonexistent/mcp-server", []})

    assert {:error, %Error{code: -32_000}} =
             Client.connect({:stdio, "snodo-no-such-command-#{System.unique_integer()}", []})
  end

  defp eventually(check, attempts \\ 50) do
    Enum.any?(1..attempts, fn _attempt ->
      check.() || (Process.sleep(20) && false)
    end)
  end
end
