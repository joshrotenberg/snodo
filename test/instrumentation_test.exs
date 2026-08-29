defmodule MCP.InstrumentationTest do
  use ExUnit.Case, async: true

  alias MCP.Instrumentation
  alias MCPEx.RaisingInstrumentationSink
  alias MCPEx.TestFixtures
  alias MCPEx.TestInstrumentationSink

  test "dispatch emits bounded start and stop events without request params" do
    runtime = TestFixtures.runtime(instrumentation: {TestInstrumentationSink, self()})

    assert {:ok, %{"result" => %{"tools" => _tools}}} =
             MCP.Test.dispatch(runtime,
               id: "observed-dispatch",
               protocol: "2026-07-28",
               method: "tools/list",
               params: %{"secret" => "must-not-appear"},
               transport_metadata: %{auth: %{"token" => "also-private"}}
             )

    assert_receive {:instrumentation, [:mcp_ex, :server, :dispatch, :start], start, metadata}

    assert is_integer(start.system_time)

    assert metadata == %{
             method: "tools/list",
             request_id: "observed-dispatch",
             transport: :direct
           }

    assert_receive {:instrumentation, [:mcp_ex, :server, :dispatch, :stop], stop, stop_metadata}

    assert is_integer(stop.duration) and stop.duration >= 0
    assert stop_metadata == Map.put(metadata, :outcome, :ok)
    refute inspect([start, metadata, stop, stop_metadata]) =~ "must-not-appear"
    refute inspect([start, metadata, stop, stop_metadata]) =~ "also-private"
  end

  test "dispatch errors and streams have explicit terminal outcomes" do
    {:ok, hub} =
      start_supervised({MCP.Subscription.Hub, instrumentation: {TestInstrumentationSink, self()}})

    runtime =
      TestFixtures.runtime(
        capabilities: %{"tools" => %{"listChanged" => true}},
        subscription_source: MCP.Subscription.Hub.source(hub),
        instrumentation: {TestInstrumentationSink, self()}
      )

    assert {:ok, %{"error" => %{"code" => -32_601}}} =
             MCP.Test.dispatch(runtime,
               id: "missing",
               protocol: "2026-07-28",
               method: "unknown/method"
             )

    assert_receive {:instrumentation, [:mcp_ex, :server, :dispatch, :start], _start,
                    %{request_id: "missing"}}

    assert_receive {:instrumentation, [:mcp_ex, :server, :dispatch, :stop], _stop,
                    %{outcome: :error, error_code: -32_601}}

    assert {:stream, subscription} =
             MCP.Test.dispatch(runtime,
               id: "observed-stream",
               protocol: "2026-07-28",
               method: "subscriptions/listen",
               params: %{"notifications" => %{"toolsListChanged" => true}}
             )

    assert_receive {:instrumentation, [:mcp_ex, :server, :dispatch, :start], _start,
                    %{request_id: "observed-stream"}}

    assert_receive {:instrumentation, [:mcp_ex, :subscription, :open], %{subscriptions: 1},
                    %{request_id: "observed-stream"}}

    assert_receive {:instrumentation, [:mcp_ex, :server, :dispatch, :stop], _stop,
                    %{outcome: :stream}}

    assert :ok = MCP.Subscription.close(subscription, :cancelled)
  end

  test "sink failures never change operations and span exceptions preserve failure" do
    config = Instrumentation.normalize!(RaisingInstrumentationSink)

    assert :ok =
             Instrumentation.emit(config, [:mcp_ex, :test], %{count: 1}, %{safe: true})

    assert_raise RuntimeError, "operation failure", fn ->
      Instrumentation.span(
        Instrumentation.normalize!({TestInstrumentationSink, self()}),
        [:mcp_ex, :operation],
        %{},
        fn -> raise "operation failure" end,
        fn _result -> %{} end
      )
    end

    assert_receive {:instrumentation, [:mcp_ex, :operation, :start], _measurements, %{}}

    assert_receive {:instrumentation, [:mcp_ex, :operation, :exception], %{duration: duration},
                    %{kind: :error, reason_class: RuntimeError}}

    assert duration >= 0
  end

  test "runtime construction rejects invalid sinks" do
    assert_raise ArgumentError, ~r/instrumentation sink/, fn ->
      TestFixtures.runtime(instrumentation: String)
    end

    assert_raise ArgumentError, ~r/instrumentation must be/, fn ->
      TestFixtures.runtime(instrumentation: self())
    end
  end
end
