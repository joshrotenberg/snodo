defmodule Snodo.HTTPRequestDeadlineTest do
  use ExUnit.Case, async: true

  alias Snodo.Server.Executor
  alias Snodo.Transport.StreamableHTTP.Server, as: HTTPServer
  alias SnodoTest.TestFixtures

  @moduletag mcp_contract: ["request-progress"]

  defmodule RepeatedProgress do
    @moduledoc false
    use Snodo.Tool, name: "repeated_progress"

    @impl true
    def call(_arguments, context) do
      Enum.each(1..100, fn value ->
        :ok = Snodo.Progress.report(context, value)
        Process.sleep(10)
      end)

      {:ok, Snodo.Result.text("must not finish before the deadline")}
    end
  end

  test "an HTTP deadline expires while queued behind unrelated infinite executor work" do
    executor =
      start_supervised!({Executor, max_concurrency: 1, max_queue: 1, default_timeout: :infinity})

    {:ok, _reference} = Executor.submit(executor, :blocker, fn _ -> Process.sleep(:infinity) end)
    port = start_http(executor: executor, request_timeout: 30)
    wire = port |> open_request() |> read_all()
    assert wire =~ "HTTP/1.1 504"
    assert wire =~ "Request execution timed out"
    assert %{running: 1, queued: 0} = Executor.stats(executor)
    assert :ok = Executor.cancel(executor, :blocker)
  end

  test "progress reports never restart the original deadline" do
    port = start_http(request_timeout: 70)
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

  defp start_http(options) do
    runtime = TestFixtures.runtime(tools: [RepeatedProgress])
    server = start_supervised!({HTTPServer, [runtime: runtime, port: 0] ++ options})
    {_ip, port, _path} = HTTPServer.address(server)
    port
  end

  defp open_request(port, options \\ []) do
    progress? = Keyword.get(options, :progress, false)
    method = if progress?, do: "tools/call", else: "tools/list"

    metadata = %{
      "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
      "io.modelcontextprotocol/clientCapabilities" => %{}
    }

    metadata = if progress?, do: Map.put(metadata, "progressToken", "deadline"), else: metadata

    params =
      if progress?,
        do: %{"name" => "repeated_progress", "_meta" => metadata},
        else: %{"_meta" => metadata}

    json = JSON.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params})
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])
    name_header = if progress?, do: "Mcp-Name: repeated_progress\r\n", else: ""

    :ok =
      :gen_tcp.send(socket, [
        "POST /mcp HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\n",
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
