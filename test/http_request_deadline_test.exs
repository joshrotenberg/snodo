defmodule Snodo.HTTPRequestDeadlineTest do
  use ExUnit.Case, async: true

  alias Snodo.Server.Executor
  alias Snodo.Transport.StreamableHTTP.Server, as: HTTPServer
  alias SnodoTest.TestFixtures

  alias SnodoTest.TestTools.Trapping

  @moduletag mcp_contract: ["request-progress"]

  defmodule RepeatedProgress do
    @moduledoc false
    use Snodo.Tool, name: "repeated_progress"

    @impl true
    def call(_arguments, context) do
      Enum.each(1..100, fn value ->
        :ok = Snodo.Progress.report(context, value)
        Process.sleep(25)
      end)

      {:ok, Snodo.Result.text("must not finish before the deadline")}
    end
  end

  test "an HTTP deadline expires while queued behind unrelated infinite executor work" do
    executor =
      start_supervised!({Executor, max_concurrency: 1, max_queue: 1, default_timeout: :infinity})

    {:ok, _reference} = Executor.submit(executor, :blocker, fn _ -> Process.sleep(:infinity) end)
    token = Integer.to_string(System.unique_integer([:positive]))
    :yes = :global.register_name({Trapping, token}, self())
    on_exit(fn -> :global.unregister_name({Trapping, token}) end)

    port = start_http(executor: executor, request_timeout: 30)
    wire = port |> open_request(trapping: token) |> read_all()
    assert wire =~ "HTTP/1.1 504"
    assert wire =~ "Request expired in the execution queue"
    assert wire =~ ~s("code":-32603)
    assert %{running: 1, queued: 0} = Executor.stats(executor)
    assert :ok = Executor.cancel(executor, :blocker)
    refute_received {:trapping_entered, _, _}
  end

  test "progress reports never restart the original deadline" do
    port = start_http(request_timeout: 500)
    wire = port |> open_request(progress: true) |> read_all()
    assert wire =~ "HTTP/1.1 200"
    assert wire =~ "notifications/progress"
    assert wire =~ "Request execution timed out"
    refute wire =~ "must not finish"
    assert length(Regex.scan(~r/notifications\/progress/, wire)) < 100
  end

  test "an explicitly infinite HTTP deadline can wait for queued work to be released" do
    executor =
      start_supervised!({Executor, max_concurrency: 1, max_queue: 1, default_timeout: :infinity})

    {:ok, _reference} = Executor.submit(executor, :blocker, fn _ -> Process.sleep(:infinity) end)
    port = start_http(executor: executor, request_timeout: :infinity)
    socket = open_request(port)
    assert {:error, :timeout} = :gen_tcp.recv(socket, 0, 40)
    assert :ok = Executor.cancel(executor, :blocker)
    assert read_all(socket) =~ "HTTP/1.1 200"
  end

  test "native HTTP forwards max_queue_wait to its owned executor" do
    server = start_http_server(max_queue_wait: 73)
    executor = :sys.get_state(server).executor

    assert :sys.get_state(executor).max_queue_wait == 73
  end

  test "native HTTP submits with a 30 second default even if the injected executor is infinite" do
    executor = start_supervised!({Executor, default_timeout: :infinity})
    token = Integer.to_string(System.unique_integer([:positive]))
    :yes = :global.register_name({Trapping, token}, self())
    on_exit(fn -> :global.unregister_name({Trapping, token}) end)

    socket = [executor: executor] |> start_http() |> open_request(trapping: token)
    assert_receive {:trapping_entered, worker, _cancellation}
    assert [%{timeout: 30_000, deadline: deadline}] = Map.values(:sys.get_state(executor).jobs)
    assert is_integer(deadline)
    send(worker, :finish)
    assert read_all(socket) =~ "HTTP/1.1 200"
  end

  defp start_http(options) do
    {_ip, port, _path} = options |> start_http_server() |> HTTPServer.address()
    port
  end

  defp start_http_server(options) do
    runtime = TestFixtures.runtime(tools: [RepeatedProgress, Trapping])
    start_supervised!({HTTPServer, [runtime: runtime, port: 0] ++ options})
  end

  defp open_request(port, options \\ []) do
    progress? = Keyword.get(options, :progress, false)
    token = Keyword.get(options, :trapping)
    tool = if token, do: "trapping", else: "repeated_progress"
    method = if progress? or token != nil, do: "tools/call", else: "tools/list"

    metadata = %{
      "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
      "io.modelcontextprotocol/clientCapabilities" => %{}
    }

    metadata = if progress?, do: Map.put(metadata, "progressToken", "deadline"), else: metadata

    params =
      cond do
        token -> %{"name" => tool, "arguments" => %{"token" => token}, "_meta" => metadata}
        progress? -> %{"name" => tool, "_meta" => metadata}
        true -> %{"_meta" => metadata}
      end

    json = JSON.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params})
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])
    name_header = if method == "tools/call", do: "Mcp-Name: #{tool}\r\n", else: ""

    :ok =
      :gen_tcp.send(socket, [
        "POST /mcp HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\nContent-Type: application/json\r\n",
        "Accept: application/json, text/event-stream\r\nMcp-Protocol-Version: 2026-07-28\r\nMcp-Method: ",
        method,
        "\r\n",
        name_header,
        "Content-Length: ",
        to_string(byte_size(json)),
        "\r\n\r\n",
        json
      ])

    socket
  end

  defp read_all(socket, acc \\ "") do
    case :gen_tcp.recv(socket, 0, 2_000) do
      {:ok, chunk} -> read_all(socket, acc <> chunk)
      {:error, :closed} -> acc
      {:error, reason} -> flunk("unexpected HTTP read failure: #{inspect(reason)}")
    end
  end
end
