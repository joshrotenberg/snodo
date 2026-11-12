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
    | `[:snodo, :server, :dispatch, *]` | the method, followed by a space and the component when one is named, such as `tools/call echo` | `:server` |
    | `[:snodo, :tasks, :runner, :job, *]` | `snodo.tasks.runner.job` | `:internal` |

    A dispatch whose method is reported as `:invalid` is named
    `snodo.server.dispatch`. The component is the registered tool or prompt
    name, or the URI of a registered direct resource. An unregistered name is
    reported as `:unknown` and left out of the span name.

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
    parent is the current OpenTelemetry context of the dispatching process,
    such as a span started by an HTTP server instrumentation.

    The dispatch span is the current span in the dispatching process until the
    dispatch ends, so spans a handler starts are its children. The previous
    context is restored when the span ends.

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

    `Snodo.Instrumentation` emits a `:stop` or an `:exception` for every
    dispatch, including one that raises. The Tasks runner emits a `:stop`
    whenever it ends a job while it keeps running; jobs still running when
    the runner itself stops get no `:stop`. A span whose process exits before
    its `:stop`, such as a job span in a runner that stops, is never ended,
    and its entry goes with the process. A `:stop` or `:exception` with no
    recorded `:start` is ignored.

    ## Failures

    The handler never raises, so `:telemetry` does not detach it. Every call
    into the OpenTelemetry API and SDK is isolated: a raise, throw, or exit
    from the SDK, such as a span processor that fails or an SDK that is
    shutting down, is caught. A failure while starting a span opens no span
    and emits `[:snodo, :open_telemetry, :span, :skipped]` with reason
    `:sdk_failure`. While ending a span, setting the attributes and status,
    ending the span, and restoring the previous context are separate steps:
    a failing step emits `[:snodo, :open_telemetry, :span, :failed]` and the
    following steps still run, so the previous context is restored.

    ## Diagnostic events

    | Event | Measurements | Metadata |
    |---|---|---|
    | `[:snodo, :open_telemetry, :span, :skipped]` | `open_spans` in the process | `span` (`:dispatch` or `:job`), `reason` (`:max_open_spans` or `:sdk_failure`) |
    | `[:snodo, :open_telemetry, :span, :failed]` | none | `span`, `step` (`:annotate`, `:end`, or `:restore`), `error_kind` (`:error`, `:throw`, or `:exit`) |

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
        do: skipped(type, :max_open_spans, open),
        else: open_and_record(type, ref, metadata, open)
    end

    defp open_and_record(type, ref, metadata, open) do
      case isolated(fn -> open_span(type, metadata) end) do
        {:ok, entry} -> put_open_spans(Map.put(open, ref, entry))
        {:error, _kind} -> skipped(type, :sdk_failure, open)
      end
    end

    defp limit(%{max_open_spans: limit}) when is_integer(limit) and limit > 0, do: limit
    defp limit(_config), do: @default_max_open_spans

    defp open_span(:dispatch, metadata) do
      parent = parent_context(metadata)

      span =
        :otel_tracer.start_span(parent, tracer(), dispatch_name(metadata), %{
          kind: :server,
          attributes: attributes(metadata, @dispatch_attributes)
        })

      token = :otel_ctx.attach(:otel_tracer.set_current_span(parent, span))
      %{type: :dispatch, span: span, restore: {:token, token}}
    end

    defp open_span(:job, metadata) do
      span =
        :otel_tracer.start_span(:otel_ctx.get_current(), tracer(), "snodo.tasks.runner.job", %{
          kind: :internal,
          attributes: attributes(metadata, @job_attributes)
        })

      %{type: :job, span: span, restore: :none}
    end

    # The entry is removed first, so a failing step below cannot leave it
    # behind; each step is isolated, so the context is restored even when
    # annotating or ending the span fails.
    defp finish_span(ref, metadata) do
      case Map.pop(open_spans(), ref) do
        {nil, _open} ->
          :ok

        {%{type: type, span: span, restore: restore}, rest} ->
          put_open_spans(rest)
          step(type, :annotate, fn -> annotate(type, span, metadata) end)
          step(type, :end, fn -> :otel_span.end_span(span) end)
          restore(type, restore)
      end
    end

    defp restore(type, {:token, token}),
      do: step(type, :restore, fn -> :otel_ctx.detach(token) end)

    defp restore(_type, :none), do: :ok

    defp annotate(:dispatch, span, metadata) do
      _set = :otel_span.set_attributes(span, attributes(metadata, @dispatch_attributes))
      set_dispatch_status(span, metadata)
    end

    defp annotate(:job, span, metadata) do
      _set = :otel_span.set_attributes(span, attributes(metadata, @job_attributes))

      if metadata[:outcome] in @failed_job_outcomes,
        do: :otel_span.set_status(span, :error, attribute_value(metadata.outcome)),
        else: false
    end

    defp set_dispatch_status(span, %{reason_class: reason_class}),
      do: :otel_span.set_status(span, :error, attribute_value(reason_class))

    defp set_dispatch_status(span, %{outcome: :error} = metadata),
      do: :otel_span.set_status(span, :error, error_message(metadata))

    defp set_dispatch_status(_span, _metadata), do: false

    defp error_message(%{error_code: code}) when is_integer(code),
      do: "JSON-RPC error " <> Integer.to_string(code)

    defp error_message(_metadata), do: "JSON-RPC error"

    defp step(type, step, fun) do
      case isolated(fun) do
        {:ok, _result} ->
          :ok

        {:error, kind} ->
          :telemetry.execute(@failed_event, %{}, %{span: type, step: step, error_kind: kind})
      end
    end

    defp skipped(type, reason, open) do
      :telemetry.execute(@skipped_event, %{open_spans: map_size(open)}, %{
        span: type,
        reason: reason
      })
    end

    defp isolated(fun) do
      {:ok, fun.()}
    catch
      kind, _reason -> {:error, kind}
    end

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
    # anything but 00 or 01.
    defp parent_context(
           %{
             traceparent:
               <<_version::binary-size(2), "-", trace_id::binary-size(32), "-",
                 span_id::binary-size(16), "-", flags::binary-size(2), _rest::binary>>
           } = metadata
         ) do
      remote =
        :otel_tracer.from_remote_span(
          String.to_integer(trace_id, 16),
          String.to_integer(span_id, 16),
          String.to_integer(flags, 16)
        )

      :otel_tracer.set_current_span(
        :otel_ctx.get_current(),
        span_ctx(remote, tracestate: tracestate(metadata))
      )
    end

    defp parent_context(_metadata), do: :otel_ctx.get_current()

    # otel_tracestate's parser and its add/3 reject W3C Trace Context Level 2
    # keys that Snodo.TraceContext accepts, such as "a@b@c", and decoding
    # drops the whole header on one such key. The members are therefore put
    # into the otel_tracestate:t() record directly, in header order, after the
    # same optional-whitespace trimming Snodo.TraceContext applied.
    defp tracestate(%{tracestate: state}) when is_binary(state) do
      members =
        for raw_member <- String.split(state, ","),
            member <- [Regex.replace(@ows, raw_member, "")],
            member != "",
            [key, value] <- [String.split(member, "=", parts: 2)],
            do: {key, value}

      {:tracestate, members}
    end

    defp tracestate(_metadata), do: :otel_tracestate.new()

    defp dispatch_name(%{method: method, component: component})
         when is_binary(method) and is_binary(component),
         do: method <> " " <> component

    defp dispatch_name(%{method: method}) when is_binary(method), do: method
    defp dispatch_name(_metadata), do: "snodo.server.dispatch"

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
