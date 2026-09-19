defmodule MCP.ProgressTest do
  use ExUnit.Case, async: true

  alias MCP.Cancellation
  alias MCP.Context
  alias MCP.Envelope
  alias MCP.Progress
  alias MCP.Protocol.Inspector
  alias MCP.Protocol.V2026_07_28
  alias MCP.Transport.Context, as: TransportContext

  @moduletag mcp_contract: ["request-progress"]

  defmodule InvalidProtocol do
    def shape_progress(_token, _fields, _context), do: %{invalid: self()}
  end

  test "reporting without an installed sink or active token is a valid-value no-op" do
    context = context()
    assert Progress.report(context, 1, total: 2, message: "working") == :ok
    assert Progress.report(context, "one") == {:error, :invalid_progress}
    sink = Progress.sink(self())

    for token <- [nil, %{}, 1.5], do: assert(Progress.bind(sink, context(token)) == nil)
    assert Progress.bind(sink, %{context | request_id: nil}) == nil
    assert Progress.bind(sink, %{context | protocol: MCP.Protocol}) == nil
    refute_receive {:"$gen_call", _, _}
  end

  test "owner shapes correlated progress and acknowledges only after accepting it" do
    {worker, sink} = worker()
    send(worker, {:report, 0.25, [total: 1.0, message: "quarter"]})
    assert_receive {:"$gen_call", from, {:mcp_progress, reference, report}}
    assert reference == sink.reference
    refute_receive {:reported, _}, 10

    assert {:ok, notification, state} = Progress.accept(Progress.state(sink), from, report)

    assert notification == %{
             "jsonrpc" => "2.0",
             "method" => "notifications/progress",
             "params" => %{
               "progressToken" => "token",
               "progress" => 0.25,
               "total" => 1.0,
               "message" => "quarter"
             }
           }

    assert state.count == 1
    assert state.last == 0.25
    assert Progress.reply(from, report, :ok) == :ok
    assert_receive {:reported, :ok}
  end

  test "strict monotonicity and per-request budgets are enforced without poisoning later reports" do
    {worker, sink} = worker(max_updates: 2)
    state = Progress.state(sink)
    state = accept_report(worker, state, 1, :ok)
    state = accept_report(worker, state, 1.0, {:error, :not_increasing})
    state = accept_report(worker, state, 0, {:error, :not_increasing})
    state = accept_report(worker, state, 1.5, :ok)
    _state = accept_report(worker, state, 2, {:error, :limit_reached})
  end

  test "invalid fields and oversized messages never enter the transport mailbox" do
    {worker, _sink} = worker(max_message_bytes: 5)

    for {value, options} <- [
          {nil, []},
          {1, [total: nil]},
          {1, [message: 2]},
          {1, [message: <<255>>]},
          {1, [message: "123456"]},
          {1, [unexpected: 2]},
          {1, [:not_a_keyword]}
        ] do
      send(worker, {:report, value, options})
      assert_receive {:reported, {:error, :invalid_progress}}
      refute_receive {:"$gen_call", _, _}, 0
    end
  end

  test "only the original request worker can report, even with a copied context" do
    {worker, _sink} = worker()
    send(worker, :context)
    assert_receive {:context, context}
    assert Progress.report(context, 1) == {:error, :wrong_process}
    assert Progress.bind(context.progress.sink, context) == nil
    refute_receive {:"$gen_call", _, _}, 0
  end

  test "a timed-out report keeps its single outstanding slot until consumed" do
    {worker, sink} = worker(timeout: 10)
    send(worker, {:report, 1, []})
    assert_receive {:"$gen_call", from, {:mcp_progress, _, report}}
    assert_receive {:reported, {:error, :timeout}}
    send(worker, {:report, 2, []})
    assert_receive {:reported, {:error, :busy}}
    refute_receive {:"$gen_call", _, _}, 0

    assert {:ok, _, state} = Progress.accept(Progress.state(sink), from, report)
    :ok = Progress.reply(from, report, :ok)
    _state = accept_report(worker, state, 2, :ok)
  end

  test "closing after a report is queued rejects it and all subsequent progress" do
    {worker, sink} = worker()
    send(worker, {:report, 1, []})
    assert_receive {:"$gen_call", from, {:mcp_progress, _, report}}
    :ok = Progress.close(sink)
    assert Progress.accept(Progress.state(sink), from, report) == {:error, :closed}
    :ok = Progress.reply(from, report, {:error, :closed})
    assert_receive {:reported, {:error, :closed}}
    send(worker, {:report, 2, []})
    assert_receive {:reported, {:error, :closed}}
    refute_receive {:"$gen_call", _, _}, 0
  end

  test "cancellation is checked before sending and again after queuing" do
    cancellation = Cancellation.new()
    {worker, sink} = worker([], %{cancellation: cancellation})
    send(worker, {:report, 1, []})
    assert_receive {:"$gen_call", from, {:mcp_progress, _, report}}
    :ok = Cancellation.cancel(cancellation)
    assert Progress.accept(Progress.state(sink), from, report) == {:error, :cancelled}
    :ok = Progress.reply(from, report, {:error, :cancelled})
    assert_receive {:reported, {:error, :cancelled}}
    send(worker, {:report, 2, []})
    assert_receive {:reported, {:error, :cancelled}}
    refute_receive {:"$gen_call", _, _}, 0
  end

  test "cross-request sink and forged producer reports are rejected" do
    {worker, sink} = worker()
    send(worker, {:report, 1, []})
    assert_receive {:"$gen_call", from, {:mcp_progress, _, report}}

    assert Progress.accept(Progress.state(Progress.sink(self())), from, report) ==
             {:error, :wrong_sink}

    assert Progress.accept(Progress.state(sink), {self(), make_ref()}, report) ==
             {:error, :wrong_sink}

    assert Progress.accept(Progress.state(sink), from, %{}) == {:error, :invalid_report}
    :ok = Progress.reply(from, report, {:error, :wrong_sink})
    assert_receive {:reported, {:error, :wrong_sink}}
  end

  test "the optional dialect hook must return a JSON-compatible notification" do
    {worker, sink} = worker([], %{protocol: InvalidProtocol})
    _state = accept_report(worker, Progress.state(sink), 1, {:error, :invalid_notification})
  end

  test "owner disappearance closes the sink instead of crashing the handler" do
    owner = spawn(fn -> :ok end)
    monitor = Process.monitor(owner)
    assert_receive {:DOWN, ^monitor, :process, ^owner, _}
    sink = Progress.sink(owner)
    context = context()
    context = %{context | progress: Progress.bind(sink, context)}
    assert Progress.report(context, 1) == {:error, :closed}
    assert Progress.report(context, 2) == {:error, :closed}
  end

  test "sink options reject unknown, zero, negative, and unbounded values" do
    for options <- [[unknown: 1], [timeout: :infinity], [max_updates: 0], [max_message_bytes: -1]] do
      assert_raise ArgumentError, fn -> Progress.sink(self(), options) end
    end
  end

  test "the implemented notification profile enforces literal progress fields and direction" do
    valid = %{"progressToken" => 0, "progress" => 0.5, "total" => 1, "message" => "half"}
    assert {:ok, %{classification: :implemented}} = inspect_progress(valid, :server_to_client)
    assert {:error, _} = inspect_progress(valid, :client_to_server)

    for params <- [
          Map.delete(valid, "progressToken"),
          Map.put(valid, "progressToken", 0.5),
          Map.delete(valid, "progress"),
          Map.put(valid, "progress", "half"),
          Map.put(valid, "total", nil),
          Map.put(valid, "message", 12)
        ] do
      assert {:error, _} = inspect_progress(params, :server_to_client)
    end
  end

  defp inspect_progress(params, direction) do
    raw = %{"jsonrpc" => "2.0", "method" => "notifications/progress", "params" => params}
    {:ok, envelope} = Envelope.decode(raw, %TransportContext{transport: :stdio})
    Inspector.inspect(V2026_07_28.profile(), envelope, direction)
  end

  defp context(token \\ "token") do
    %Context{
      protocol_version: "2026-07-28",
      protocol: V2026_07_28,
      transport: %TransportContext{transport: :stdio},
      request_id: "request",
      request_method: "tools/call",
      metadata: %{"progressToken" => token}
    }
  end

  defp worker(options \\ [], context_fields \\ %{}) do
    sink = Progress.sink(self(), options)
    owner = self()

    worker =
      spawn_link(fn ->
        context = struct!(context(), context_fields)
        context = %{context | progress: Progress.bind(sink, context)}
        worker_loop(owner, context)
      end)

    on_exit(fn -> Process.exit(worker, :kill) end)
    {worker, sink}
  end

  defp worker_loop(owner, context) do
    receive do
      {:report, value, options} ->
        send(owner, {:reported, Progress.report(context, value, options)})
        worker_loop(owner, context)

      :context ->
        send(owner, {:context, context})
        worker_loop(owner, context)
    end
  end

  defp accept_report(worker, state, value, expected) do
    send(worker, {:report, value, []})
    assert_receive {:"$gen_call", from, {:mcp_progress, _, report}}

    next_state =
      case Progress.accept(state, from, report) do
        {:ok, _, next_state} ->
          assert expected == :ok
          next_state

        {:error, _} = error ->
          assert error == expected
          state
      end

    :ok = Progress.reply(from, report, expected)
    assert_receive {:reported, ^expected}
    next_state
  end
end
