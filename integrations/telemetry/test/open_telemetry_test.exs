defmodule Snodo.Instrumentation.Telemetry.OpenTelemetryTest do
  # The :telemetry handler and the SDK exporter are global, so the tests run
  # one at a time.
  use ExUnit.Case, async: false

  require OpenTelemetry.Tracer, as: Tracer
  require Record

  alias Snodo.Extensions.Tasks.Runner
  alias Snodo.Extensions.Tasks.Store.Memory
  alias Snodo.Instrumentation
  alias Snodo.Instrumentation.Telemetry
  alias Snodo.Instrumentation.Telemetry.OpenTelemetry, as: Spans
  alias SnodoTest.Telemetry.Blocking
  alias SnodoTest.Telemetry.FailingProcessor
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

  @skipped [:snodo, :open_telemetry, :span, :skipped]
  @failed [:snodo, :open_telemetry, :span, :failed]

  setup do
    owner = self()

    # The processor logs each exporter change at the info level.
    _log =
      ExUnit.CaptureLog.capture_log(fn ->
        :ok = :otel_simple_processor.set_exporter(:otel_exporter_pid, owner)
      end)

    diagnostics = {__MODULE__, make_ref()}
    :ok = :telemetry.attach_many(diagnostics, [@skipped, @failed], &__MODULE__.forward/4, owner)

    :ok = Spans.attach()

    on_exit(fn ->
      FailingProcessor.set_mode(:off)
      :telemetry.detach(diagnostics)
      Spans.detach(open_spans: :abandon)
    end)

    :ok
  end

  def forward(event_name, measurements, metadata, owner) do
    send(owner, {:diagnostic, event_name, measurements, metadata})
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

    assert_receive {:span, span(name: "mcp.request") = exported}

    assert span(exported, :status) == status(code: :error, message: "JSON-RPC error -32601")

    assert %{
             "snodo.method" => "unknown/method",
             "snodo.outcome" => "error",
             "snodo.error_code" => -32_601
           } = attributes(exported)

    assert_clean_process()
  end

  describe "span names" do
    test "a routed method with a result is the span name" do
      runtime = TracedServer.runtime(instrumentation: Telemetry)

      assert {:ok, %{"result" => _result}} =
               Snodo.Test.dispatch(runtime,
                 id: "otel-list",
                 protocol: "2026-07-28",
                 method: "tools/list"
               )

      assert_receive {:span, span(name: "tools/list") = exported}
      assert %{"snodo.method" => "tools/list", "snodo.outcome" => "ok"} = attributes(exported)
      assert_clean_process()
    end

    test "methods nothing routes keep the fixed name and stay an attribute" do
      runtime = TracedServer.runtime(instrumentation: Telemetry)
      chosen = for index <- 1..3, do: "client/chosen-#{index}-" <> String.duplicate("x", 100)
      longest = String.duplicate("y", 128)

      for method <- [longest | chosen] do
        assert {:ok, %{"error" => %{"code" => -32_601}}} =
                 Snodo.Test.dispatch(runtime, id: method, protocol: "2026-07-28", method: method)
      end

      # A notification is never answered, so it says nothing about routing.
      notification = %{
        "jsonrpc" => "2.0",
        "method" => "notifications/client-chosen",
        "params" => %{"_meta" => Snodo.Protocol.V2026_07_28.request_metadata(%{})}
      }

      assert {:ok, nil} =
               Snodo.Server.dispatch(runtime, notification, %Snodo.Transport.Context{
                 transport: :direct
               })

      exported =
        for _span <- 1..5 do
          assert_receive {:span, span(name: "mcp.request") = exported}
          attributes(exported)["snodo.method"]
        end

      assert Enum.sort(exported) ==
               Enum.sort(["notifications/client-chosen", longest | chosen])

      refute_received {:span, _other}
      assert_clean_process()
    end

    test "a method over the length limit is reported as invalid and keeps the fixed name" do
      runtime = TracedServer.runtime(instrumentation: Telemetry)
      method = String.duplicate("z", 129)

      assert {:ok, %{"error" => _error}} =
               Snodo.Test.dispatch(runtime,
                 id: "too-long",
                 protocol: "2026-07-28",
                 method: method
               )

      assert_receive {:span, span(name: "mcp.request") = exported}
      assert %{"snodo.method" => "invalid"} = attributes(exported)
      refute inspect(exported) =~ method
    end
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

    # The unknown tool is an error, so the method is left out of the name too.
    assert_receive {:span, span(name: "mcp.request") = exported}

    assert %{"snodo.method" => "tools/call", "snodo.component" => "unknown"} =
             attributes(exported)

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

    assert_receive {:span, span(name: "mcp.request") = exported}

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
      Instrumentation.emit(config, @dispatch ++ [:exception], %{duration: 1}, %{
        method: "orphan",
        kind: :error,
        reason_class: RuntimeError
      })

    :ok =
      Instrumentation.emit(config, @job ++ [:stop], %{duration: 1, jobs: 0}, %{task_id: "orphan"})

    # Events that do not come through Snodo.Instrumentation.Telemetry carry no
    # span context and are ignored too.
    :ok = :telemetry.execute(@dispatch ++ [:start], %{system_time: 0}, %{method: "no-context"})

    marker(config)

    assert_receive {:span, span(name: "marker")}
    refute_received {:span, _other}
    refute_received {:diagnostic, _event, _measurements, _metadata}
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
    refute List.keymember?(dictionary, {Spans, :open_spans}, 0)
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

  # Stdio runs each request in a task of its executor: a new process, with an
  # empty OpenTelemetry context, that the executor kills on timeout or cancel.
  describe "through the stdio transport" do
    test "the parent comes from a traceparent only, and handler spans are children" do
      outer = start_outer_span()

      responses =
        serve_stdio([
          stdio_call("stdio-traced", "traced", %{}, %{"traceparent" => @traceparent}),
          stdio_call("stdio-untraced", "echo", %{"text" => "x"}, %{})
        ])

      assert %{"stdio-traced" => %{"result" => _traced}, "stdio-untraced" => %{"result" => _echo}} =
               responses

      assert_receive {:span, span(name: "handler work") = child}
      assert_receive {:span, span(name: "tools/call traced") = traced}
      assert_receive {:span, span(name: "tools/call echo") = untraced}

      assert span(traced, :trace_id) == String.to_integer(@trace_id, 16)
      assert span(traced, :parent_span_id) == String.to_integer(@parent_id, 16)
      assert %{"snodo.transport" => "stdio"} = attributes(traced)

      # The tool runs in the executor task, the process that emitted the start.
      assert span(child, :parent_span_id) == span(traced, :span_id)

      # The test process has a current span, but the executor task does not
      # inherit it: without a traceparent the dispatch span is a root.
      assert span(untraced, :parent_span_id) == :undefined
      refute span(untraced, :trace_id) == :otel_span.trace_id(outer)
      assert_clean_process(outer)
    end

    test "a dispatch killed on timeout ends no span and the handler stays attached" do
      token = Integer.to_string(System.unique_integer([:positive]))
      :yes = :global.register_name({Blocking, token}, self())
      on_exit(fn -> :global.unregister_name({Blocking, token}) end)

      request =
        stdio_call("stdio-timeout", "blocking", %{"token" => token}, %{
          "traceparent" => @traceparent
        })

      assert %{"stdio-timeout" => %{"error" => %{"message" => "Request execution timed out"}}} =
               serve_stdio([request], request_timeout: 250)

      # The span was started in the worker, which the executor then killed.
      assert_received {:blocking, worker, dispatch_span}
      refute Process.alive?(worker)
      assert :otel_span.trace_id(dispatch_span) == String.to_integer(@trace_id, 16)

      # Neither a stop nor an exception was emitted, so nothing was exported.
      marker(Instrumentation.normalize!(Telemetry))
      assert_receive {:span, span(name: "marker")}
      refute_received {:span, span(name: "tools/call blocking")}
      assert_clean_process()

      attached =
        for event <- Spans.events(),
            %{function: function} <- :telemetry.list_handlers(event),
            function == (&Spans.handle_event/4),
            do: event

      assert Enum.sort(attached) == Enum.sort(Spans.events())

      assert %{"stdio-after" => %{"result" => _result}} =
               serve_stdio([stdio_call("stdio-after", "echo", %{"text" => "x"}, %{})])

      assert_receive {:span, span(name: "tools/call echo")}

      # The unended span stays in the SDK until its sweeper drops it. The test
      # ends it so it does not outlive the test; it has no outcome.
      _ended = :otel_span.end_span(dispatch_span)
      assert_receive {:span, span(name: "tools/call blocking") = abandoned}
      refute Map.has_key?(attributes(abandoned), "snodo.outcome")
      assert_clean_process()
    end
  end

  describe "parent context" do
    test "a dispatch restores an existing current context" do
      outer = start_outer_span()

      dispatch_echo(TracedServer.runtime(instrumentation: Telemetry), %{})

      assert_receive {:span, span(name: "tools/call echo") = exported}
      assert span(exported, :parent_span_id) == :otel_span.span_id(outer)
      assert span(exported, :trace_id) == :otel_span.trace_id(outer)
      assert_clean_process(outer)
    end

    test "a traceparent replaces the current context as parent, which is then restored" do
      outer = start_outer_span()

      dispatch_echo(TracedServer.runtime(instrumentation: Telemetry), %{
        "traceparent" => @traceparent
      })

      assert_receive {:span, span(name: "tools/call echo") = exported}
      assert span(exported, :parent_span_id) == String.to_integer(@parent_id, 16)
      assert_clean_process(outer)
    end

    test "trace flags are a bit mask: 03 is sampled and keeps the parent" do
      dispatch_echo(TracedServer.runtime(instrumentation: Telemetry), %{
        "traceparent" => "00-#{@trace_id}-#{@parent_id}-03"
      })

      assert_receive {:span, span(name: "tools/call echo") = exported}
      assert span(exported, :trace_id) == String.to_integer(@trace_id, 16)
      assert span(exported, :parent_span_id) == String.to_integer(@parent_id, 16)
      assert_clean_process()
    end

    test "trace flags 02 leave the sampled bit unset, so the parent-based sampler drops the span" do
      dispatch_echo(TracedServer.runtime(instrumentation: Telemetry), %{
        "traceparent" => "00-#{@trace_id}-#{@parent_id}-02"
      })

      # A lost parent would give a sampled root span; a kept one is unsampled.
      marker(Instrumentation.normalize!(Telemetry))

      assert_receive {:span, span(name: "marker")}
      refute_received {:span, span(name: "tools/call echo")}
      assert_clean_process()
    end

    test "a future traceparent version keeps the parent" do
      future = "01-#{@trace_id}-#{@parent_id}-01-future field"

      dispatch_echo(TracedServer.runtime(instrumentation: Telemetry), %{"traceparent" => future})

      assert_receive {:span, span(name: "tools/call echo") = exported}
      assert span(exported, :parent_span_id) == String.to_integer(@parent_id, 16)
    end

    test "a Level 2 tracestate is kept as Snodo.TraceContext accepted it" do
      dispatch_echo(TracedServer.runtime(instrumentation: Telemetry), %{
        "traceparent" => @traceparent,
        "tracestate" => "1vendor=x, a@b@c=y"
      })

      assert_receive {:span, span(name: "tools/call echo") = exported}
      tracestate = span(exported, :tracestate)

      assert span(exported, :parent_span_id) == String.to_integer(@parent_id, 16)
      assert :otel_tracestate.get("a@b@c", tracestate) == "y"
      assert :otel_tracestate.get("1vendor", tracestate) == "x"
      assert :otel_tracestate.encode_header(tracestate) == "1vendor=x,a@b@c=y"
    end

    test "malformed trace fields fall back to the current context" do
      outer = start_outer_span()

      dispatch_echo(TracedServer.runtime(instrumentation: Telemetry), %{
        "traceparent" => "00-#{@trace_id}-0000000000000000-01",
        "tracestate" => "vendor=x"
      })

      assert_receive {:span, span(name: "tools/call echo") = exported}
      assert span(exported, :parent_span_id) == :otel_span.span_id(outer)
      assert span(exported, :trace_id) == :otel_span.trace_id(outer)
      assert :otel_tracestate.encode_header(span(exported, :tracestate)) == ""
      assert_clean_process(outer)
    end

    test "a malformed tracestate keeps the parent and drops only the state" do
      dispatch_echo(TracedServer.runtime(instrumentation: Telemetry), %{
        "traceparent" => @traceparent,
        "tracestate" => "rojo=a,rojo=b"
      })

      assert_receive {:span, span(name: "tools/call echo") = exported}
      assert span(exported, :parent_span_id) == String.to_integer(@parent_id, 16)
      assert :otel_tracestate.encode_header(span(exported, :tracestate)) == ""
    end
  end

  describe "SDK failures" do
    test "a processor raising on end does not detach the handler and the context is restored" do
      runtime = TracedServer.runtime(instrumentation: Telemetry)
      outer = start_outer_span()
      FailingProcessor.set_mode(:raise_on_end)

      dispatch_echo(runtime, %{})

      assert_receive {:diagnostic, @failed, %{}, metadata}

      assert metadata == %{
               span: :dispatch,
               operation: :end,
               reason: :sdk_failure,
               error_kind: :error,
               error_class: RuntimeError
             }

      # The failing processor runs before the exporting one, so nothing is
      # exported, but the context is restored and the handler stays attached.
      refute_received {:span, span(name: "tools/call echo")}
      assert_clean_process(outer)

      FailingProcessor.set_mode(:off)
      dispatch_echo(runtime, %{})
      assert_receive {:span, span(name: "tools/call echo")}
      assert_clean_process(outer)
    end

    test "a processor exiting on end is isolated too" do
      FailingProcessor.set_mode(:exit_on_end)
      config = Instrumentation.normalize!(Telemetry)

      assert :done =
               Instrumentation.span(config, @job, %{task_id: "t"}, fn -> :done end, fn _ ->
                 %{outcome: :completed}
               end)

      assert_receive {:diagnostic, @failed, %{}, metadata}

      assert metadata == %{
               span: :job,
               operation: :end,
               reason: :sdk_failure,
               error_kind: :exit,
               error_class: :exit
             }

      assert_clean_process()
    end

    test "a processor raising on start skips the span and leaves the context alone" do
      runtime = TracedServer.runtime(instrumentation: Telemetry)
      outer = start_outer_span()
      FailingProcessor.set_mode(:raise_on_start)

      dispatch_echo(runtime, %{})

      assert_receive {:diagnostic, @skipped, %{open_spans: 0}, metadata}

      # The bounded classification only: no message and no raw reason.
      assert metadata == %{
               span: :dispatch,
               operation: :start,
               reason: :sdk_failure,
               error_kind: :error,
               error_class: RuntimeError
             }

      refute_received {:span, span(name: "tools/call echo")}
      refute_received {:diagnostic, @failed, _measurements, _metadata}
      assert_clean_process(outer)
    end
  end

  describe "handler failures" do
    test "metadata that breaks the contract is reported apart from SDK failures" do
      outer = start_outer_span()
      ref = make_ref()

      # Shaped like a traceparent but not hex, which Snodo.TraceContext would
      # never pass on, so the handler's own parsing fails.
      bad = "00-#{String.duplicate("z", 32)}-#{String.duplicate("z", 16)}-01"

      :telemetry.execute(@dispatch ++ [:start], %{system_time: 0}, %{
        method: "tools/list",
        traceparent: bad,
        telemetry_span_context: ref
      })

      assert_receive {:diagnostic, @skipped, %{open_spans: 0}, metadata}

      assert metadata == %{
               span: :dispatch,
               operation: :start,
               reason: :handler_failure,
               error_kind: :error,
               error_class: ArgumentError
             }

      :telemetry.execute(@dispatch ++ [:stop], %{duration: 1}, %{
        outcome: :ok,
        telemetry_span_context: ref
      })

      refute_received {:span, span(name: "tools/list")}
      refute_received {:diagnostic, @failed, _measurements, _metadata}
      assert_clean_process(outer)
    end
  end

  describe "open span limit" do
    test "a start at the limit opens no span and emits the skipped event" do
      :ok = Spans.detach(open_spans: :abandon)
      :ok = Spans.attach(max_open_spans: 1)
      config = Instrumentation.normalize!(Telemetry)
      finish = fn _result -> %{outcome: :ok} end

      inner = fn ->
        Instrumentation.span(config, @dispatch, %{method: "inner"}, fn -> :inner end, finish)
      end

      assert :inner = Instrumentation.span(config, @dispatch, %{method: "outer"}, inner, finish)

      assert_receive {:diagnostic, @skipped, %{open_spans: 1},
                      %{span: :dispatch, operation: :start, reason: :max_open_spans} = metadata}

      assert map_size(metadata) == 3

      assert_receive {:span, span(name: "outer")}
      refute_received {:span, span(name: "inner")}
      assert_clean_process()
    end

    test "starts whose stops never arrive hold slots until the limit, then free them" do
      :ok = Spans.detach(open_spans: :abandon)
      :ok = Spans.attach(max_open_spans: 2)
      start = %{jobs: 1, system_time: 0}
      refs = for _job <- 1..3, do: make_ref()

      for {ref, index} <- Enum.with_index(refs) do
        :telemetry.execute(@job ++ [:start], start, %{
          task_id: "missed-#{index}",
          telemetry_span_context: ref
        })
      end

      assert_receive {:diagnostic, @skipped, %{open_spans: 2},
                      %{span: :job, operation: :start, reason: :max_open_spans}}

      assert map_size(Process.get({Spans, :open_spans})) == 2

      for ref <- refs do
        :telemetry.execute(@job ++ [:stop], %{duration: 1, jobs: 0}, %{
          outcome: :completed,
          telemetry_span_context: ref
        })
      end

      assert_receive {:span, span(name: "snodo.tasks.runner.job") = first}
      assert_receive {:span, span(name: "snodo.tasks.runner.job") = second}
      refute_received {:span, _third}

      assert Enum.sort([attributes(first)["snodo.task_id"], attributes(second)["snodo.task_id"]]) ==
               ["missed-0", "missed-1"]

      assert_clean_process()
    end

    test "invalid options raise" do
      assert_raise ArgumentError, ~r/:max_open_spans must be a positive integer/, fn ->
        Spans.attach(max_open_spans: 0)
      end

      assert_raise ArgumentError, fn -> Spans.attach(handler_id: :other) end

      assert_raise ArgumentError, ~r/:open_spans must be :finish or :abandon/, fn ->
        Spans.detach(open_spans: :drop)
      end
    end
  end

  describe "attach and detach" do
    test "only one span handler can be attached" do
      assert {:error, :already_exists} = Spans.attach()
      assert {:error, :already_exists} = Spans.attach(max_open_spans: 5)

      handlers =
        for event <- Spans.events(),
            %{function: function} <- :telemetry.list_handlers(event),
            function == (&Spans.handle_event/4),
            do: event

      assert Enum.sort(handlers) == Enum.sort(Spans.events())

      dispatch_echo(TracedServer.runtime(instrumentation: Telemetry), %{})

      assert_receive {:span, span(name: "tools/call echo")}
      refute_received {:span, _second}
      assert_clean_process()
    end

    test "detach during a dispatch ends the open span and restores the context" do
      config = Instrumentation.normalize!(Telemetry)
      finish = fn _result -> %{outcome: :ok} end

      assert :ok =
               Instrumentation.span(
                 config,
                 @dispatch,
                 %{method: "detaching"},
                 &Spans.detach/0,
                 finish
               )

      assert_receive {:span, span(name: "detaching")}
      assert_clean_process()

      # New dispatches open no span once the start handler is gone.
      Instrumentation.span(config, @dispatch, %{method: "after"}, fn -> :ok end, finish)
      refute_received {:span, span(name: "after")}

      assert {:error, :not_found} = Spans.detach()
      assert :ok = Spans.attach()
    end

    test "detach with open_spans: :abandon leaves the open span as documented" do
      config = Instrumentation.normalize!(Telemetry)
      finish = fn _result -> %{outcome: :ok} end

      detach = fn ->
        current = :otel_tracer.current_span_ctx()
        :ok = Spans.detach(open_spans: :abandon)
        current
      end

      abandoned = Instrumentation.span(config, @dispatch, %{method: "abandoned"}, detach, finish)

      refute_received {:span, _abandoned}
      assert [_entry] = Map.values(Process.get({Spans, :open_spans}))
      assert :otel_tracer.current_span_ctx() == abandoned
      assert {:error, :not_found} = Spans.detach(open_spans: :abandon)

      # The test owns the abandoned span now: end it, then clear what the
      # handler left in this process. It never got an outcome, so it keeps the
      # name it started with.
      _ended = :otel_span.end_span(abandoned)
      assert_receive {:span, span(name: "mcp.request") = exported}
      assert %{"snodo.method" => "abandoned"} = attributes(exported)
      _entry = Process.delete({Spans, :open_spans})
      _previous = :otel_ctx.attach(:otel_ctx.new())
    end
  end

  # A span the test owns, made current in the test process. on_exit resets
  # the failing processor before ending it: test on_exit callbacks run before
  # the one registered in setup.
  defp start_outer_span do
    outer = Tracer.start_span("outer")
    Tracer.set_current_span(outer)

    on_exit(fn ->
      FailingProcessor.set_mode(:off)
      _ended = :otel_span.end_span(outer)
    end)

    outer
  end

  defp dispatch_echo(runtime, meta) do
    assert {:ok, %{"result" => _result}} =
             Snodo.Test.dispatch(runtime,
               id: "otel-echo",
               protocol: "2026-07-28",
               method: "tools/call",
               params: %{"name" => "echo", "arguments" => %{"text" => "x"}, "_meta" => meta}
             )
  end

  # Serves the requests over stdio until EOF and every request has finished,
  # and returns the responses by id.
  defp serve_stdio(requests, options \\ []) do
    input = Enum.map_join(requests, &(JSON.encode!(&1) <> "\n"))
    {:ok, io} = StringIO.open(input)
    runtime = TracedServer.runtime(instrumentation: Telemetry)

    assert :ok =
             Snodo.Transport.Stdio.serve(runtime, Keyword.merge(options, input: io, output: io))

    {_input, output} = StringIO.contents(io)

    for line <- String.split(output, "\n", trim: true),
        response = JSON.decode!(line),
        into: %{},
        do: {response["id"], response}
  end

  defp stdio_call(id, tool, arguments, meta) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "tools/call",
      "params" => %{
        "name" => tool,
        "arguments" => arguments,
        "_meta" => Map.merge(Snodo.Protocol.V2026_07_28.request_metadata(%{}), meta)
      }
    }
  end

  # A dispatch span named "marker". The simple processor exports a span
  # before end_span returns, so every span ended earlier arrives first.
  defp marker(config) do
    Instrumentation.span(config, @dispatch, %{method: "marker"}, fn -> :ok end, fn _result ->
      %{outcome: :ok}
    end)
  end

  defp attributes(exported), do: :otel_attributes.map(span(exported, :attributes))

  defp assert_clean_process(current \\ :undefined) do
    assert Process.get({Spans, :open_spans}) == nil
    assert :otel_tracer.current_span_ctx() == current
  end
end
