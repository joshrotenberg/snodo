defmodule Snodo.Instrumentation.Telemetry.OpenTelemetryTest do
  # The :telemetry handler and the SDK exporter are global, so the tests run
  # one at a time.
  use ExUnit.Case, async: false

  require Record

  alias Snodo.Extensions.Tasks.Runner
  alias Snodo.Extensions.Tasks.Store.Memory
  alias Snodo.Instrumentation
  alias Snodo.Instrumentation.Telemetry
  alias Snodo.Instrumentation.Telemetry.OpenTelemetry, as: Spans
  alias SnodoTest.Telemetry.Tasks, as: TasksFixtures
  alias SnodoTest.Telemetry.TracedServer

  Record.defrecordp(
    :span,
    Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl")
  )

  Record.defrecordp(
    :status,
    Record.extract(:status, from_lib: "opentelemetry_api/include/opentelemetry.hrl")
  )

  @dispatch [:snodo, :server, :dispatch]
  @job [:snodo, :tasks, :runner, :job]

  @trace_id "4bf92f3577b34da6a3ce929d0e0e4736"
  @parent_id "00f067aa0ba902b7"
  @traceparent "00-#{@trace_id}-#{@parent_id}-01"

  setup do
    owner = self()

    # The processor logs each exporter change at the info level.
    _log =
      ExUnit.CaptureLog.capture_log(fn ->
        :ok = :otel_simple_processor.set_exporter(:otel_exporter_pid, owner)
      end)

    :ok = Spans.attach()
    on_exit(fn -> Spans.detach() end)
    :ok
  end

  test "a tool call becomes a server span named for the method and the tool" do
    runtime = TracedServer.runtime(instrumentation: Telemetry)

    assert {:ok, %{"result" => _result}} =
             Snodo.Test.dispatch(runtime,
               id: "otel-call",
               protocol: "2026-07-28",
               method: "tools/call",
               params: %{"name" => "echo", "arguments" => %{"text" => "private input"}}
             )

    assert_receive {:span, span(name: "tools/call echo") = exported}

    assert span(exported, :kind) == :server
    assert span(exported, :parent_span_id) == :undefined
    assert span(exported, :status) == :undefined

    assert attributes(exported) == %{
             "snodo.method" => "tools/call",
             "snodo.request_id" => "otel-call",
             "snodo.transport" => "direct",
             "snodo.component" => "echo",
             "snodo.outcome" => "ok"
           }

    refute inspect(exported) =~ "private input"
    assert_clean_process()
  end

  test "a traceparent in _meta is the parent of the dispatch span" do
    runtime = TracedServer.runtime(instrumentation: Telemetry)

    assert {:ok, %{"result" => _result}} =
             Snodo.Test.dispatch(runtime,
               id: "otel-traced",
               protocol: "2026-07-28",
               method: "tools/call",
               params: %{
                 "name" => "echo",
                 "arguments" => %{"text" => "hello"},
                 "_meta" => %{"traceparent" => @traceparent, "tracestate" => "vendor=opaque"}
               }
             )

    assert_receive {:span, span(name: "tools/call echo") = exported}

    assert span(exported, :trace_id) == String.to_integer(@trace_id, 16)
    assert span(exported, :parent_span_id) == String.to_integer(@parent_id, 16)
    assert span(exported, :parent_span_is_remote) == true
    assert :otel_tracestate.get("vendor", span(exported, :tracestate)) == "opaque"

    # The trace fields set the parent; they are not recorded as attributes.
    refute Map.has_key?(attributes(exported), "snodo.traceparent")
    refute Map.has_key?(attributes(exported), "snodo.tracestate")
    assert_clean_process()
  end

  test "a span started by a handler is a child of the dispatch span" do
    runtime = TracedServer.runtime(instrumentation: Telemetry)

    assert {:ok, %{"result" => _result}} =
             Snodo.Test.dispatch(runtime,
               id: "otel-child",
               protocol: "2026-07-28",
               method: "tools/call",
               params: %{
                 "name" => "traced",
                 "arguments" => %{},
                 "_meta" => %{"traceparent" => @traceparent}
               }
             )

    assert_receive {:span, span(name: "handler work") = child}
    assert_receive {:span, span(name: "tools/call traced") = dispatch}

    assert span(child, :trace_id) == String.to_integer(@trace_id, 16)
    assert span(child, :parent_span_id) == span(dispatch, :span_id)
    assert_clean_process()
  end

  test "a JSON-RPC error sets the error status and the error code" do
    runtime = TracedServer.runtime(instrumentation: Telemetry)

    assert {:ok, %{"error" => %{"code" => -32_601}}} =
             Snodo.Test.dispatch(runtime,
               id: "otel-missing",
               protocol: "2026-07-28",
               method: "unknown/method"
             )

    assert_receive {:span, span(name: "unknown/method") = exported}

    assert span(exported, :status) == status(code: :error, message: "JSON-RPC error -32601")
    assert %{"snodo.outcome" => "error", "snodo.error_code" => -32_601} = attributes(exported)
    assert_clean_process()
  end

  test "an unregistered tool is left out of the span name" do
    runtime = TracedServer.runtime(instrumentation: Telemetry)

    assert {:ok, _response} =
             Snodo.Test.dispatch(runtime,
               id: "otel-unknown-tool",
               protocol: "2026-07-28",
               method: "tools/call",
               params: %{"name" => "client-chosen-name", "arguments" => %{}}
             )

    assert_receive {:span, span(name: "tools/call") = exported}

    assert %{"snodo.component" => "unknown"} = attributes(exported)
    refute inspect(exported) =~ "client-chosen-name"
  end

  test "an exception ends the span with the error status and restores the context" do
    config = Instrumentation.normalize!(Telemetry)
    metadata = %{method: "tools/call", request_id: "raising", transport: :direct}

    assert_raise RuntimeError, "private failure detail", fn ->
      Instrumentation.span(
        config,
        @dispatch,
        metadata,
        fn -> raise "private failure detail" end,
        fn _result -> %{outcome: :ok} end
      )
    end

    assert_receive {:span, span(name: "tools/call") = exported}

    assert span(exported, :status) == status(code: :error, message: "RuntimeError")

    assert attributes(exported) == %{
             "snodo.method" => "tools/call",
             "snodo.request_id" => "raising",
             "snodo.transport" => "direct",
             "snodo.kind" => "error",
             "snodo.reason_class" => "RuntimeError"
           }

    refute inspect(exported) =~ "private failure detail"
    assert_clean_process()
  end

  test "nested dispatches nest their spans" do
    config = Instrumentation.normalize!(Telemetry)
    finish = fn _result -> %{outcome: :ok} end

    inner = fn ->
      Instrumentation.span(config, @dispatch, %{method: "inner"}, fn -> :inner end, finish)
    end

    assert :inner = Instrumentation.span(config, @dispatch, %{method: "outer"}, inner, finish)

    assert_receive {:span, span(name: "inner") = inner_span}
    assert_receive {:span, span(name: "outer") = outer_span}

    assert span(inner_span, :parent_span_id) == span(outer_span, :span_id)
    assert span(inner_span, :trace_id) == span(outer_span, :trace_id)
    assert_clean_process()
  end

  test "a stop or exception with no recorded start is ignored" do
    config = Instrumentation.normalize!(Telemetry)

    :ok = Instrumentation.emit(config, @dispatch ++ [:stop], %{duration: 1}, %{method: "orphan"})

    :ok =
      Instrumentation.emit(config, @job ++ [:stop], %{duration: 1, jobs: 0}, %{task_id: "orphan"})

    # Events that do not come through Snodo.Instrumentation.Telemetry carry no
    # span context and are ignored too.
    :ok = :telemetry.execute(@dispatch ++ [:start], %{system_time: 0}, %{method: "no-context"})

    Instrumentation.span(config, @dispatch, %{method: "marker"}, fn -> :ok end, fn _ -> %{} end)

    assert_receive {:span, span(name: "marker")}
    refute_received {:span, _other}
    assert_clean_process()
  end

  test "a runner job becomes an internal span with the job metadata" do
    store = start_supervised!({Memory, scope: :shared})
    runner = start_supervised!({Runner, store: {Memory, store}, instrumentation: Telemetry})
    runtime = TasksFixtures.runtime(store, runner, Telemetry)

    assert {:ok, %{"result" => %{"taskId" => task_id}}} =
             Snodo.Test.dispatch(runtime,
               id: "otel-task",
               protocol: "2026-07-28",
               client_capabilities: TasksFixtures.client_capabilities(),
               method: "tools/call",
               params: %{
                 "name" => "echo",
                 "arguments" => %{"text" => "private input"},
                 "_meta" => %{"traceparent" => @traceparent}
               }
             )

    assert_receive {:span, span(name: "tools/call echo") = dispatch}
    assert_receive {:span, span(name: "snodo.tasks.runner.job") = job}

    assert span(job, :kind) == :internal
    assert span(job, :status) == :undefined

    assert attributes(job) == %{
             "snodo.task_id" => task_id,
             "snodo.revision" => 0,
             "snodo.source" => "request",
             "snodo.outcome" => "completed",
             "snodo.store_outcome" => "applied",
             "snodo.release_outcome" => "ok"
           }

    # Runner job events carry no trace context, so the job span starts its own
    # trace rather than joining the dispatch's.
    assert span(job, :parent_span_id) == :undefined
    refute span(job, :trace_id) == span(dispatch, :trace_id)

    refute inspect([dispatch, job]) =~ "private input"
    {:dictionary, dictionary} = Process.info(runner, :dictionary)
    refute Enum.any?(dictionary, &match?({{Spans, _ref}, _span}, &1))
  end

  test "interleaved job spans end by task and a failed job sets the error status" do
    config = Instrumentation.normalize!(Telemetry)
    start = %{jobs: 2, system_time: System.system_time()}
    stop = %{duration: 1, jobs: 1}

    :ok = Instrumentation.emit(config, @job ++ [:start], start, %{task_id: "a", revision: 0})
    :ok = Instrumentation.emit(config, @job ++ [:start], start, %{task_id: "b", revision: 0})

    :ok =
      Instrumentation.emit(config, @job ++ [:stop], stop, %{task_id: "b", outcome: :completed})

    :ok =
      Instrumentation.emit(config, @job ++ [:stop], stop, %{task_id: "a", outcome: :max_runtime})

    assert_receive {:span, span(name: "snodo.tasks.runner.job") = first}
    assert_receive {:span, span(name: "snodo.tasks.runner.job") = second}

    assert %{"snodo.task_id" => "b", "snodo.outcome" => "completed"} = attributes(first)
    assert span(first, :status) == :undefined

    assert %{"snodo.task_id" => "a", "snodo.outcome" => "max_runtime"} = attributes(second)
    assert span(second, :status) == status(code: :error, message: "max_runtime")

    # Job spans are not made current, so neither is the other's parent.
    assert span(first, :parent_span_id) == :undefined
    assert span(second, :parent_span_id) == :undefined
    assert_clean_process()
  end

  test "attach and detach report a duplicate and a missing handler" do
    assert {:error, :already_exists} = Spans.attach()
    assert :ok = Spans.attach(handler_id: :second)
    assert :ok = Spans.detach(handler_id: :second)
    assert {:error, :not_found} = Spans.detach(handler_id: :second)
  end

  defp attributes(exported), do: :otel_attributes.map(span(exported, :attributes))

  defp assert_clean_process do
    refute Enum.any?(Process.get_keys(), &match?({Spans, _ref}, &1))
    assert :otel_tracer.current_span_ctx() == :undefined
  end
end
