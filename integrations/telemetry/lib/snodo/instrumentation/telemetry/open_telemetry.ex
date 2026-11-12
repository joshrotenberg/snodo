if Code.ensure_loaded?(:otel_tracer) do
  defmodule Snodo.Instrumentation.Telemetry.OpenTelemetry do
    @moduledoc """
    OpenTelemetry spans from the `:telemetry` events that
    `Snodo.Instrumentation.Telemetry` emits.

    This module is compiled only when the application depends on
    `opentelemetry_api`. Configure `Snodo.Instrumentation.Telemetry` as the
    instrumentation sink, configure an OpenTelemetry SDK, and attach the
    handler once, for example in `Application.start/2`:

        :ok = Snodo.Instrumentation.Telemetry.OpenTelemetry.attach()

    ## Spans

    The handler starts a span on each `:start` event and ends it on the
    matching `:stop` or `:exception` event, paired by the
    `telemetry_span_context` reference that `Snodo.Instrumentation.Telemetry`
    adds. Events without that reference are ignored. A span's `:start` and
    its `:stop` or `:exception` must be emitted by the same process, because
    the open span is kept in that process; `Snodo.Instrumentation` and the
    Tasks runner both do so.

    | Events | Span name | Kind |
    |---|---|---|
    | `[:snodo, :server, :dispatch, *]` | the method and the component, such as `tools/call echo`, when a component is named; otherwise `mcp.request`, renamed to the method when the dispatch returns a result | `:server` |
    | `[:snodo, :tasks, :runner, :job, *]` | `snodo.tasks.runner.job` | `:internal` |

    The method is chosen by the client, so it is put in a dispatch span name
    only when the server's configuration bounds it:

      * The component is the registered tool or prompt name, or the URI of a
        registered direct resource, for `tools/call`, `prompts/get`, and
        `resources/read`. An unregistered name is reported as `:unknown` and
        left out of the span name. A span with a named component has its name
        from the start and keeps it whatever the outcome, including a
        JSON-RPC error, an exception, or a dispatch that never ends.
      * Otherwise the span starts as `mcp.request`. When the dispatch ends
        with outcome `:ok` or `:stream`, which only a route the server
        registers can produce, the span is renamed to the method.
      * A span without a named component keeps `mcp.request` on a JSON-RPC
        error, a notification (outcome `:no_reply`), an exception, a method
        reported as `:invalid`, or a dispatch that never ends, because those
        can come from a method nothing routes, such as one answered with
        method not found.

    The method is still recorded as the `snodo.method` attribute;
    `Snodo.Server` reports a method longer than 128 bytes as `:invalid`. A
    sampler sees the name the span starts with.

    Attributes come from the event metadata, under the metadata key with a
    `snodo.` prefix: `snodo.method`, `snodo.request_id`, `snodo.transport`,
    `snodo.component`, `snodo.outcome`, `snodo.error_code`, `snodo.kind`, and
    `snodo.reason_class` for a dispatch; `snodo.task_id`, `snodo.revision`,
    `snodo.source`, `snodo.outcome`, `snodo.store_outcome`, and
    `snodo.release_outcome` for a runner job. Atoms are recorded as strings.
    The events carry no request params, auth data, work input, results, or
    errors, so the spans do not either.

    A dispatch span's status is set to error when the response is a JSON-RPC
    error or the dispatch raised, with the error code or the exception class
    as the message. A runner job span's status is set to error when the job
    outcome is `:failed`, `:invalid`, `:worker_terminated`, or `:max_runtime`,
    with the outcome as the message. Other spans keep the unset status.
    Whether a span is recorded at all is up to the SDK's sampler; with the
    default parent-based sampler, a `traceparent` whose sampled flag (bit 0
    of the trace flags) is not set produces an unrecorded dispatch span.

    ## Parent context

    When request `_meta` carries a valid W3C `traceparent`, the dispatch
    events carry it as `:traceparent`, with `:tracestate` when that is valid
    too, and the dispatch span's parent is that remote span. The remote span
    context is built from the fields `Snodo.TraceContext` validated: the
    trace flags are kept whole and read as a bit mask, and the tracestate is
    kept as accepted, including W3C Trace Context Level 2 keys. Otherwise the
    parent is the current OpenTelemetry context of the process that emits the
    `:start` event, the process that calls `Snodo.Server.dispatch/3`.

    The stdio, native HTTP, and Plug transports call it in a task of their
    executor (`Snodo.Server.Executor`), a new process whose OpenTelemetry
    context is empty. A context the connection or request process holds,
    such as a span from an HTTP server instrumentation, is not seen there.
    Under those transports the dispatch span therefore has a parent only when
    the client sends a `traceparent`, and is a root otherwise. A dispatch
    that the application calls in a process with a current span, such as
    `Snodo.Test.dispatch/2` or its own call to `Snodo.Server.dispatch/3`, gets
    that span as the parent.

    The dispatch span is the current span in that process until the dispatch
    ends, and the previous context is restored when the span ends. A span a
    handler starts is a child of the dispatch span only when it is started in
    the same process. A component wrapped in `Snodo.Component.Wrap.Timeout`
    runs in another task, and so does any work the handler spawns; spans
    started there have no parent unless the context is passed to them.

    Runner job events carry no trace context, and they are emitted in the
    runner process, not the process that submitted the work. A runner job
    span is therefore not linked to the dispatch that created the task: its
    parent is the runner process's current context, which is normally empty,
    so the job span starts a new trace. It is not made the current span,
    because jobs for different tasks interleave in the runner process.

    ## Open spans and the limit

    Open spans are kept in one process dictionary entry of the emitting
    process, a map from the `telemetry_span_context` reference to the span,
    and removed when the matching `:stop` or `:exception` arrives. The entry
    is deleted when no span is open.

    A process holds at most `:max_open_spans` open spans, 1,024 by default.
    At the limit a `:start` opens no span: the observed operation continues
    unchanged, its `:stop` is ignored, and the handler emits a
    `[:snodo, :open_telemetry, :span, :skipped]` event with reason
    `:max_open_spans`. Nested dispatches in one process use one slot each.
    Every running job of a Tasks runner uses a slot in the runner process, so
    keep the limit at or above the runner's `:max_jobs` (32 by default).

    `Snodo.Instrumentation` emits a `:stop` or an `:exception` for a
    dispatch that returns or raises. A dispatch whose process is killed
    emits neither: under the stdio, native HTTP, and Plug transports the
    executor kills the task on a request timeout, on a cancellation, and when
    the connection that owns the request goes away. The Tasks runner emits a
    `:stop` whenever it ends a job while it keeps running; jobs still running
    when the runner itself stops get no `:stop`.

    A span whose process exits before its `:stop` or `:exception` is never
    ended by this handler and is not exported, and its entry goes with the
    process. The SDK keeps the span until its span sweeper removes it; with
    the SDK's defaults the sweeper runs every 10 minutes and drops spans
    older than 30 minutes without exporting them. A `:stop` or `:exception`
    with no recorded `:start` is ignored.

    ## Limits

      * A dispatch killed on timeout or cancel, and a job still running when
        its runner stops, leave their spans unended, as described above.
      * The SDK sweeper also removes a span that is still open: with the
        default 30-minute TTL, a Tasks job that runs longer than that loses
        its span, and its later `:stop` ends nothing. Raise the SDK's
        `:sweeper` `:span_ttl` above the longest job's runtime (the runner's
        `:max_runtime_ms`, one hour by default), or set its strategy to
        `:end_span` to export swept spans.
      * The optional dependency is `opentelemetry_api ~> 1.5`. The tests run
        against 1.5 with the 1.7 SDK. 1.4 is left out: no test runs against
        it, and its `span_ctx` record, from which the handler builds the
        remote parent, has a different layout.
      * The test suite always compiles this module. Building the package
        without `opentelemetry_api`, where this module is left out, is not
        covered by the tests.

    ## Failures

    The handler never raises, so `:telemetry` does not detach it. Its own
    preparation (the span name, the attributes, the status message, and the
    parsed remote parent) and its calls into the OpenTelemetry API and SDK
    are isolated separately, so a raise, throw, or exit is caught and
    reported as `:handler_failure` or `:sdk_failure`. An SDK failure can come
    from a span processor that fails or an SDK that is shutting down; a
    handler failure means the event metadata broke its contract or the
    handler has a bug.

    A failure while starting a span opens no span and emits
    `[:snodo, :open_telemetry, :span, :skipped]`. Ending a span is three
    operations: annotate (attributes, name, and status), end, and restore the
    previous context. A failing operation emits
    `[:snodo, :open_telemetry, :span, :failed]` and the following operations
    still run, so the previous context is restored.

    ## Diagnostic events

    | Event | Measurements | Metadata |
    |---|---|---|
    | `[:snodo, :open_telemetry, :span, :skipped]` | `open_spans` in the process | `span`, `operation` (`:start`), `reason` (`:max_open_spans`, `:handler_failure`, or `:sdk_failure`); a failure adds `error_kind` and `error_class` |
    | `[:snodo, :open_telemetry, :span, :failed]` | none | `span`, `operation` (`:annotate`, `:end`, or `:restore`), `reason` (`:handler_failure` or `:sdk_failure`), `error_kind`, `error_class` |

    `span` is `:dispatch` or `:job`. `error_kind` is `:error`, `:throw`, or
    `:exit`. `error_class` is the exception module for `:error`, such as
    `RuntimeError` or `ArgumentError` (a raw Erlang error is normalized, so
    `:badarg` is `ArgumentError`), and is `:throw` or `:exit` for those kinds.
    Exception messages and raw reasons are never included.

    ## Detaching

    `detach/1` stops new spans at once. By default the handler for `:stop`
    and `:exception` events stays attached, so spans already open are ended
    and their contexts restored as usual; a later `attach/1` reuses it. With
    `open_spans: :abandon` both handlers are removed: spans open at that
    moment are never ended, and their entries, and for a dispatch its
    current context, stay in their processes until those processes exit.

    `:telemetry` runs the handler synchronously in the emitting process.
    """

    require Record

    Record.defrecordp(
      :span_ctx,
      Record.extract(:span_ctx, from_lib: "opentelemetry_api/include/opentelemetry.hrl")
    )

    @dispatch [:snodo, :server, :dispatch]
    @job [:snodo, :tasks, :runner, :job]

    @start_events [@dispatch ++ [:start], @job ++ [:start]]
    @finish_events [@dispatch ++ [:stop], @dispatch ++ [:exception], @job ++ [:stop]]

    @start_handler {__MODULE__, :start}
    @finish_handler {__MODULE__, :finish}

    @open_spans_key {__MODULE__, :open_spans}
    @default_max_open_spans 1_024

    @skipped_event [:snodo, :open_telemetry, :span, :skipped]
    @failed_event [:snodo, :open_telemetry, :span, :failed]

    @dispatch_attributes [
      :method,
      :request_id,
      :transport,
      :component,
      :outcome,
      :error_code,
      :kind,
      :reason_class
    ]

    @job_attributes [:task_id, :revision, :source, :outcome, :store_outcome, :release_outcome]

    @failed_job_outcomes [:failed, :invalid, :worker_terminated, :max_runtime]

    @request_name "mcp.request"
    @routed_outcomes [:ok, :stream]

    @ows ~r/\A[ \t]+|[ \t]+\z/

    @doc """
    The `:telemetry` events the handler attaches to.
    """
    @spec events() :: [[atom(), ...], ...]
    def events, do: @start_events ++ @finish_events

    @doc """
    Attaches the span handler to `events/0`.

    Only one span handler can be attached at a time. Returns
    `{:error, :already_exists}` when it is already attached.

    ## Options

      * `:max_open_spans` - the most spans open at once in one process, a
        positive integer. Defaults to 1,024. A `:start` at the limit opens no
        span and emits `[:snodo, :open_telemetry, :span, :skipped]`.

    Raises `ArgumentError` for an unknown option or an invalid value.
    """
    @spec attach(keyword()) :: :ok | {:error, :already_exists}
    def attach(options \\ []) do
      options = Keyword.validate!(options, max_open_spans: @default_max_open_spans)
      max_open_spans = max_open_spans!(options[:max_open_spans])

      # The finish handler goes first, so every span the start handler opens
      # has a handler to end it. A finish handler left by detach/1 is reused.
      _finish =
        :telemetry.attach_many(@finish_handler, @finish_events, &__MODULE__.handle_event/4, nil)

      :telemetry.attach_many(
        @start_handler,
        @start_events,
        &__MODULE__.handle_event/4,
        %{max_open_spans: max_open_spans}
      )
    end

    defp max_open_spans!(value) when is_integer(value) and value > 0, do: value

    defp max_open_spans!(value) do
      raise ArgumentError, ":max_open_spans must be a positive integer, got: #{inspect(value)}"
    end

    @doc """
    Detaches the span handler.

    ## Options

      * `:open_spans` - what happens to spans open when this runs.
        `:finish`, the default, removes only the handler for `:start` events,
        so open spans are ended and their contexts restored when their
        `:stop` or `:exception` arrives. `:abandon` removes both handlers;
        open spans are never ended, and their entries stay in their
        processes until those processes exit.

    Returns `{:error, :not_found}` when there was nothing to detach.
    """
    @spec detach(keyword()) :: :ok | {:error, :not_found}
    def detach(options \\ []) do
      options = Keyword.validate!(options, open_spans: :finish)

      case options[:open_spans] do
        :finish ->
          :telemetry.detach(@start_handler)

        :abandon ->
          results = [:telemetry.detach(@start_handler), :telemetry.detach(@finish_handler)]
          if :ok in results, do: :ok, else: {:error, :not_found}

        other ->
          raise ArgumentError, ":open_spans must be :finish or :abandon, got: #{inspect(other)}"
      end
    end

    @doc false
    @spec handle_event([atom(), ...], map(), map(), term()) :: :ok
    def handle_event(event_name, _measurements, %{telemetry_span_context: ref} = metadata, config) do
      case List.pop_at(event_name, -1) do
        {:start, @dispatch} -> start_span(:dispatch, ref, metadata, config)
        {:start, @job} -> start_span(:job, ref, metadata, config)
        {finish, @dispatch} when finish in [:stop, :exception] -> finish_span(ref, metadata)
        {:stop, @job} -> finish_span(ref, metadata)
        _other -> :ok
      end
    end

    def handle_event(_event_name, _measurements, _metadata, _config), do: :ok

    defp start_span(type, ref, metadata, config) do
      open = open_spans()

      if map_size(open) >= limit(config),
        do: skipped(type, open, %{operation: :start, reason: :max_open_spans}),
        else: open_and_record(type, ref, metadata, open)
    end

    # The handler's own preparation and the SDK calls are isolated separately,
    # so a failure is reported as :handler_failure or :sdk_failure.
    defp open_and_record(type, ref, metadata, open) do
      with {:ok, prepared} <- attempt(:handler_failure, fn -> prepare_start(type, metadata) end),
           {:ok, entry} <- attempt(:sdk_failure, fn -> sdk_start(type, prepared) end) do
        put_open_spans(Map.put(open, ref, entry))
      else
        {:error, failure} -> skipped(type, open, Map.put(failure, :operation, :start))
      end
    end

    defp limit(%{max_open_spans: limit}) when is_integer(limit) and limit > 0, do: limit
    defp limit(_config), do: @default_max_open_spans

    defp prepare_start(:dispatch, metadata) do
      %{
        name: dispatch_name(metadata),
        kind: :server,
        attributes: attributes(metadata, @dispatch_attributes),
        remote: remote_parent(metadata)
      }
    end

    defp prepare_start(:job, metadata) do
      %{
        name: "snodo.tasks.runner.job",
        kind: :internal,
        attributes: attributes(metadata, @job_attributes),
        remote: nil
      }
    end

    defp sdk_start(:dispatch, prepared) do
      parent = parent_context(prepared.remote)
      span = :otel_tracer.start_span(parent, tracer(), prepared.name, start_options(prepared))
      token = :otel_ctx.attach(:otel_tracer.set_current_span(parent, span))
      %{type: :dispatch, span: span, name: prepared.name, restore: {:token, token}}
    end

    defp sdk_start(:job, prepared) do
      span =
        :otel_tracer.start_span(
          :otel_ctx.get_current(),
          tracer(),
          prepared.name,
          start_options(prepared)
        )

      %{type: :job, span: span, name: prepared.name, restore: :none}
    end

    defp start_options(prepared), do: %{kind: prepared.kind, attributes: prepared.attributes}

    # The entry is removed first, so a failing operation below cannot leave it
    # behind; each operation is isolated, so the context is restored even when
    # annotating or ending the span fails.
    defp finish_span(ref, metadata) do
      case Map.pop(open_spans(), ref) do
        {nil, _open} ->
          :ok

        {%{type: type, span: span, name: name, restore: restore}, rest} ->
          put_open_spans(rest)
          annotate(type, span, name, metadata)
          sdk_operation(type, :end, fn -> :otel_span.end_span(span) end)
          restore(type, restore)
      end
    end

    defp annotate(type, span, started_name, metadata) do
      case attempt(:handler_failure, fn -> prepare_finish(type, started_name, metadata) end) do
        {:ok, annotation} ->
          sdk_operation(type, :annotate, fn -> apply_annotation(span, annotation) end)

        {:error, failure} ->
          failed(type, Map.put(failure, :operation, :annotate))
      end
    end

    defp restore(type, {:token, token}),
      do: sdk_operation(type, :restore, fn -> :otel_ctx.detach(token) end)

    defp restore(_type, :none), do: :ok

    defp prepare_finish(:dispatch, started_name, metadata) do
      %{
        attributes: attributes(metadata, @dispatch_attributes),
        status: dispatch_status(metadata),
        rename: rename(started_name, dispatch_name(metadata))
      }
    end

    defp prepare_finish(:job, _started_name, metadata),
      do: %{attributes: attributes(metadata, @job_attributes), status: job_status(metadata)}

    defp rename(same, same), do: nil
    defp rename(_started_name, name), do: name

    defp apply_annotation(span, annotation) do
      _set = :otel_span.set_attributes(span, annotation.attributes)
      _renamed = update_name(span, Map.get(annotation, :rename))
      set_error_status(span, annotation.status)
    end

    defp update_name(_span, nil), do: false
    defp update_name(span, name), do: :otel_span.update_name(span, name)

    defp set_error_status(_span, nil), do: false
    defp set_error_status(span, message), do: :otel_span.set_status(span, :error, message)

    defp dispatch_status(%{reason_class: reason_class}), do: attribute_value(reason_class)

    defp dispatch_status(%{outcome: :error, error_code: code}) when is_integer(code),
      do: "JSON-RPC error " <> Integer.to_string(code)

    defp dispatch_status(%{outcome: :error}), do: "JSON-RPC error"
    defp dispatch_status(_metadata), do: nil

    defp job_status(%{outcome: outcome}) when outcome in @failed_job_outcomes,
      do: attribute_value(outcome)

    defp job_status(_metadata), do: nil

    defp sdk_operation(type, operation, fun) do
      case attempt(:sdk_failure, fun) do
        {:ok, _result} -> :ok
        {:error, failure} -> failed(type, Map.put(failure, :operation, operation))
      end
    end

    defp failed(type, failure) do
      :telemetry.execute(@failed_event, %{}, Map.put(failure, :span, type))
    end

    defp skipped(type, open, details) do
      :telemetry.execute(
        @skipped_event,
        %{open_spans: map_size(open)},
        Map.put(details, :span, type)
      )
    end

    # Runs fun and turns a raise, throw, or exit into a bounded failure: the
    # reason, the kind, and the exception module for an error or the kind
    # itself for a throw or exit. Messages and raw reasons are not kept.
    defp attempt(reason, fun) do
      {:ok, fun.()}
    catch
      kind, caught ->
        {:error,
         %{
           reason: reason,
           error_kind: kind,
           error_class: classify(kind, caught, __STACKTRACE__)
         }}
    end

    defp classify(:error, caught, stacktrace),
      do: Exception.normalize(:error, caught, stacktrace).__struct__

    defp classify(kind, _caught, _stacktrace), do: kind

    defp open_spans, do: Process.get(@open_spans_key, %{})

    defp put_open_spans(open) when map_size(open) == 0 do
      _previous = Process.delete(@open_spans_key)
      :ok
    end

    defp put_open_spans(open) do
      _previous = Process.put(@open_spans_key, open)
      :ok
    end

    # The dispatch metadata holds only a traceparent that Snodo.TraceContext
    # validated, and a tracestate only alongside one. The remote span context
    # is built from those fields rather than parsed again by
    # otel_propagator_trace_context, which drops a parent whose flags are
    # anything but 00 or 01. Parsing is the handler's own work; building the
    # span context is left to parent_context/1, inside the SDK isolation.
    defp remote_parent(
           %{
             traceparent:
               <<_version::binary-size(2), "-", trace_id::binary-size(32), "-",
                 span_id::binary-size(16), "-", flags::binary-size(2), _rest::binary>>
           } = metadata
         ) do
      %{
        trace_id: String.to_integer(trace_id, 16),
        span_id: String.to_integer(span_id, 16),
        flags: String.to_integer(flags, 16),
        tracestate_members: tracestate_members(metadata)
      }
    end

    defp remote_parent(_metadata), do: nil

    defp parent_context(nil), do: :otel_ctx.get_current()

    defp parent_context(remote) do
      span_ctx =
        :otel_tracer.from_remote_span(remote.trace_id, remote.span_id, remote.flags)

      :otel_tracer.set_current_span(
        :otel_ctx.get_current(),
        span_ctx(span_ctx, tracestate: tracestate(remote.tracestate_members))
      )
    end

    # otel_tracestate's parser and its add/3 reject W3C Trace Context Level 2
    # keys that Snodo.TraceContext accepts, such as "a@b@c", and decoding
    # drops the whole header on one such key. The members are therefore put
    # into the otel_tracestate:t() record directly, in header order, after the
    # same optional-whitespace trimming Snodo.TraceContext applied.
    defp tracestate_members(%{tracestate: state}) when is_binary(state) do
      for raw_member <- String.split(state, ","),
          member <- [Regex.replace(@ows, raw_member, "")],
          member != "",
          [key, value] <- [String.split(member, "=", parts: 2)],
          do: {key, value}
    end

    defp tracestate_members(_metadata), do: nil

    defp tracestate(nil), do: :otel_tracestate.new()
    defp tracestate(members), do: {:tracestate, members}

    # The method is client-chosen, so it goes into the span name only when the
    # server's configuration bounds it. A component is named only when the
    # router registers it, and only for tools/call, prompts/get, and
    # resources/read, so that name holds whatever the outcome. Without one, a
    # result or a stream comes only from a route the server registers, so the
    # method is known once the outcome is :ok or :stream; the start metadata
    # has no outcome, so the span starts as mcp.request and is renamed when it
    # ends. Errors, notifications, and exceptions can come from methods
    # nothing routes, so without a component they keep the fixed name.
    defp dispatch_name(%{method: method, component: component})
         when is_binary(method) and is_binary(component),
         do: method <> " " <> component

    defp dispatch_name(%{method: method, outcome: outcome})
         when is_binary(method) and outcome in @routed_outcomes,
         do: method

    defp dispatch_name(_metadata), do: @request_name

    defp attributes(metadata, keys) do
      for key <- keys,
          value <- [attribute_value(Map.get(metadata, key))],
          value != nil,
          into: %{},
          do: {"snodo." <> Atom.to_string(key), value}
    end

    defp attribute_value(nil), do: nil
    defp attribute_value(value) when is_binary(value) or is_integer(value), do: value

    defp attribute_value(value) when is_atom(value) do
      case Atom.to_string(value) do
        "Elixir." <> name -> name
        name -> name
      end
    end

    defp attribute_value(_value), do: nil

    defp tracer, do: :opentelemetry.get_application_tracer(__MODULE__)
  end
end
