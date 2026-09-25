defmodule Snodo.ProgressTransportAcceptanceTest do
  use ExUnit.Case, async: true

  alias Snodo.Cancellation
  alias Snodo.Server
  alias Snodo.Server.Executor
  alias Snodo.Transport.Context, as: TransportContext
  alias Snodo.Transport.Stdio
  alias Snodo.Transport.StreamableHTTP.Server, as: HTTPServer
  alias SnodoTest.TestFixtures
  alias SnodoTest.TestInput

  @moduletag mcp_contract: ["request-progress"]

  defmodule Tool do
    use Snodo.Tool, name: "progress_probe"

    @impl true
    def call(arguments, context) do
      :ok = Snodo.Progress.report(context, 0, total: 1, message: "starting")
      wait_for_controller(arguments, context)
      :ok = Snodo.Progress.report(context, 0.5, total: 1)
      finish(Map.get(arguments, "finish", "complete"))
    end

    defp wait_for_controller(%{"controller" => name}, context) do
      send(:global.whereis_name({__MODULE__, name}), {:entered, self(), context})

      receive do
        :continue -> :ok
      end
    end

    defp wait_for_controller(_arguments, _context), do: :ok

    defp finish("error"), do: {:error, Snodo.Error.invalid_params("requested failure")}

    defp finish("input_required") do
      request = Snodo.Elicitation.form("Choose", %{"type" => "object", "properties" => %{}})
      {:ok, Snodo.Result.input_required(input_requests: %{"choice" => request})}
    end

    defp finish("complete"), do: {:ok, Snodo.Result.text("complete")}
  end

  test "direct synchronous dispatch safely ignores reporting without a transport sink" do
    assert {:ok, %{"id" => "direct", "result" => %{"resultType" => "complete"}}} =
             Server.dispatch(runtime(), request("direct"), %TransportContext{transport: :direct})

    refute_receive {:"$gen_call", _, _}, 0
  end

  test "the dialect keeps subscription progress separate from ordinary request streams" do
    transport = %TransportContext{
      transport: :stdio,
      metadata: %{progress_sink: Snodo.Progress.sink(self())}
    }

    raw = request("listen") |> Map.put("method", "subscriptions/listen")
    assert {:ok, envelope} = Snodo.Envelope.decode(raw, transport)
    assert {:ok, context} = Snodo.Protocol.V2026_07_28.build_context(envelope, runtime())
    assert context.progress == nil
  end

  test "stdio emits exact correlated progress before one final complete/error/MRTR response" do
    for finish <- ["complete", "error", "input_required"], token <- ["token", 0] do
      raw = request(finish, %{"finish" => finish}, token)
      [first, second, final] = stdio(raw)
      assert_progress(first, token, 0)
      assert_progress(second, token, 0.5)
      assert_final(final, finish, finish)
    end
  end

  test "requests without progress tokens preserve a single JSON response on both transports" do
    raw = request("silent") |> update_in(["params", "_meta"], &Map.delete(&1, "progressToken"))
    assert [%{"id" => "silent", "result" => _}] = stdio(raw)
    port = start_http()
    response = raw |> open_request(port) |> receive_all()
    assert response =~ "Content-Type: application/json"
    [_headers, json] = String.split(response, "\r\n\r\n", parts: 2)
    assert JSON.decode!(json)["id"] == "silent"
  end

  test "stdio serializes concurrent request progress independently before their own finals" do
    requests = for id <- 1..12, do: request(id, %{}, id)
    input = Enum.map_join(requests, "", &(JSON.encode!(&1) <> "\n"))
    responses = stdio_input(input)
    assert length(responses) == 36

    for id <- 1..12 do
      related =
        Enum.filter(responses, fn message ->
          message["id"] == id or get_in(message, ["params", "progressToken"]) == id
        end)

      assert [first, second, final] = related
      assert_progress(first, id, 0)
      assert_progress(second, id, 0.5)
      assert_final(final, id, "complete")
    end
  end

  test "stdio writes progress before completion and cancellation prevents any later wire message" do
    controller = controller()
    {:ok, input} = TestInput.start_link()
    {:ok, output} = StringIO.open("")
    task = Task.async(fn -> Stdio.serve(runtime(), input: input, output: output) end)
    TestInput.push(input, JSON.encode!(request("cancel", %{"controller" => controller})) <> "\n")
    assert_receive {:entered, worker, context}, 1_000
    monitor = Process.monitor(worker)
    assert [first] = output_messages(output)
    assert_progress(first, "token", 0)

    cancel = %{
      "jsonrpc" => "2.0",
      "method" => "notifications/cancelled",
      "params" => %{"requestId" => "cancel"}
    }

    TestInput.push(input, JSON.encode!(cancel) <> "\n")
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}, 1_000
    assert Cancellation.cancelled?(context.cancellation)
    assert eventually(fn -> :atomics.get(context.progress.sink.lifecycle, 1) == 1 end)
    TestInput.eof(input)
    assert Task.await(task) == :ok
    assert output_messages(output) == [first]
  end

  test "native HTTP starts the originating SSE response before work completes" do
    controller = controller()
    port = start_http()
    socket = open_request(request("live", %{"controller" => controller}), port)
    assert_receive {:entered, worker, context}, 1_000
    first_wire = receive_until(socket, "\r\n\r\ndata: ")
    assert first_wire =~ "HTTP/1.1 200"
    assert first_wire =~ "Content-Type: text/event-stream"
    assert [first] = sse_messages(first_wire)
    assert_progress(first, "token", 0)
    refute first_wire =~ "\"id\""
    send(worker, :continue)
    wire = receive_all(socket, first_wire)
    assert [^first, second, final] = sse_messages(wire)
    assert_progress(second, "token", 0.5)
    assert_final(final, "live", "complete")
    assert :atomics.get(context.progress.sink.lifecycle, 1) == 1
    assert length(String.split(wire, "HTTP/1.1")) == 2
  end

  test "native HTTP sends one final JSON-RPC error or MRTR response after progress" do
    port = start_http()

    for finish <- ["error", "input_required"] do
      wire = request(finish, %{"finish" => finish}) |> open_request(port) |> receive_all()
      assert wire =~ "HTTP/1.1 200"
      assert [first, second, final] = sse_messages(wire)
      assert_progress(first, "token", 0)
      assert_progress(second, "token", 0.5)
      assert_final(final, finish, finish)
    end
  end

  test "HTTP request deadline becomes a terminal SSE error after progress" do
    controller = controller()
    port = start_http(request_timeout: 100)
    socket = open_request(request("timeout", %{"controller" => controller}), port)
    assert_receive {:entered, _worker, context}, 1_000
    wire = receive_all(socket)
    assert [first, final] = sse_messages(wire)
    assert_progress(first, "token", 0)
    assert final["id"] == "timeout"
    assert final["error"]["message"] == "Request execution timed out"
    assert Cancellation.cancelled?(context.cancellation)
  end

  test "HTTP disconnect cancels only its originating progress request" do
    controller = controller()
    executor = start_supervised!({Executor, []})
    port = start_http(executor: executor)
    socket = open_request(request("disconnected", %{"controller" => controller}), port)
    assert_receive {:entered, worker, context}, 1_000
    monitor = Process.monitor(worker)
    # Observe the real executor's incoming cancellation before it kills work.
    # Worker DOWN alone cannot order a different process's later cleanup.
    observer = %{owner: self(), sink: context.progress.sink}
    :ok = :sys.install(executor, {&observe_cancellation/3, observer})
    assert [_first] = socket |> receive_until("\r\n\r\ndata: ") |> sse_messages()
    :ok = :gen_tcp.close(socket)
    assert_receive {:sink_closed_before_cancellation, 1}, 1_000
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}, 1_000
    assert Cancellation.cancelled?(context.cancellation)
    assert :atomics.get(context.progress.sink.lifecycle, 1) == 1

    wire = request("unrelated") |> open_request(port) |> receive_all()
    assert [_, _, %{"id" => "unrelated", "result" => _}] = sse_messages(wire)
  end

  defp observe_cancellation(
         %{owner: owner, sink: sink} = state,
         {:in, {:"$gen_call", _from, {:cancel, _key, :peer_closed}}},
         _process_state
       ) do
    send(owner, {:sink_closed_before_cancellation, :atomics.get(sink.lifecycle, 1)})
    state
  end

  defp observe_cancellation(state, _event, _process_state), do: state

  test "native HTTP isolates concurrent request tokens and exactly one final per connection" do
    port = start_http()

    1..8
    |> Task.async_stream(fn id ->
      request(id, %{}, id) |> open_request(port) |> receive_all() |> sse_messages()
    end)
    |> Enum.with_index(1)
    |> Enum.each(fn {{:ok, [first, second, final]}, id} ->
      assert_progress(first, id, 0)
      assert_progress(second, id, 0.5)
      assert_final(final, id, "complete")
    end)
  end

  defp controller do
    name = Integer.to_string(System.unique_integer([:positive]))
    :yes = :global.register_name({Tool, name}, self())
    on_exit(fn -> :global.unregister_name({Tool, name}) end)
    name
  end

  defp runtime, do: TestFixtures.runtime(tools: [Tool])

  defp request(id, arguments \\ %{}, token \\ "token") do
    TestFixtures.request(id, "tools/call", %{
      "name" => "progress_probe",
      "arguments" => arguments,
      "_meta" => %{
        "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
        "io.modelcontextprotocol/clientCapabilities" => %{"elicitation" => %{"form" => %{}}},
        "progressToken" => token
      }
    })
  end

  defp stdio(raw), do: stdio_input(JSON.encode!(raw) <> "\n")

  defp stdio_input(text) do
    {:ok, input} = StringIO.open(text)
    {:ok, output} = StringIO.open("")
    assert Stdio.serve(runtime(), input: input, output: output) == :ok
    output_messages(output)
  end

  defp output_messages(output) do
    {_input, text} = StringIO.contents(output)
    text |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)
  end

  defp eventually(function, attempts \\ 100)

  defp eventually(function, attempts) when attempts > 0 do
    if function.() do
      true
    else
      Process.sleep(1)
      eventually(function, attempts - 1)
    end
  end

  defp eventually(_function, 0), do: false

  defp start_http(options \\ []) do
    server = start_supervised!({HTTPServer, [runtime: runtime(), port: 0] ++ options})
    {_ip, port, _path} = HTTPServer.address(server)
    port
  end

  defp open_request(raw, port) do
    body = JSON.encode!(raw)
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])

    :ok =
      :gen_tcp.send(socket, [
        "POST /mcp HTTP/1.1\r\nHost: localhost\r\n",
        "Content-Type: application/json\r\nAccept: application/json, text/event-stream\r\n",
        "MCP-Protocol-Version: 2026-07-28\r\nMcp-Method: tools/call\r\n",
        "Mcp-Name: progress_probe\r\nContent-Length: ",
        Integer.to_string(byte_size(body)),
        "\r\n\r\n",
        body
      ])

    socket
  end

  defp receive_all(socket, text \\ "") do
    case :gen_tcp.recv(socket, 0, 2_000) do
      {:ok, chunk} -> receive_all(socket, text <> chunk)
      {:error, :closed} -> text
      {:error, reason} -> flunk("unexpected socket failure: #{inspect(reason)}")
    end
  end

  defp receive_until(socket, marker, text \\ "") do
    if String.contains?(text, marker) and String.ends_with?(text, "\r\n\r\n") do
      text
    else
      {:ok, chunk} = :gen_tcp.recv(socket, 0, 2_000)
      receive_until(socket, marker, text <> chunk)
    end
  end

  defp sse_messages(wire) do
    [_headers, body] = String.split(wire, "\r\n\r\n", parts: 2)

    body
    |> String.split("\r\n\r\n", trim: true)
    |> Enum.map(fn "data: " <> json -> JSON.decode!(json) end)
  end

  defp assert_progress(message, token, value) do
    assert message["jsonrpc"] == "2.0"
    assert message["method"] == "notifications/progress"
    assert message["params"]["progressToken"] == token
    assert message["params"]["progress"] == value
    refute Map.has_key?(message, "id")
    refute Map.has_key?(message["params"], "_meta")
  end

  defp assert_final(message, id, "error") do
    assert message["id"] == id
    assert message["error"] == %{"code" => -32_602, "message" => "requested failure"}
  end

  defp assert_final(message, id, result_type) do
    assert message["id"] == id
    assert message["result"]["resultType"] == result_type
    refute Map.has_key?(message, "method")
  end
end
