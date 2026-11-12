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
    adds. Events without that reference are ignored.

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
    default parent-based sampler, a `traceparent` whose sampled flag is not
    set produces an unrecorded dispatch span.

    ## Parent context

    When request `_meta` carries a valid W3C `traceparent`, the dispatch
    events carry it as `:traceparent`, with `:tracestate` when that is valid
    too, and the dispatch span's parent is that remote span. Otherwise the
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

    ## Open spans

    An open span is kept in the process dictionary of the emitting process,
    under a key holding the `telemetry_span_context` reference, and removed
    when the matching `:stop` or `:exception` arrives, so the number of
    entries in a process is the number of spans open in it. The handler adds
    no limit of its own.

    `Snodo.Instrumentation` emits a `:stop` or an `:exception` for every
    dispatch, including one that raises. The Tasks runner emits a `:stop`
    whenever it ends a job while it keeps running; jobs still running when
    the runner itself stops get no `:stop`. A span whose process exits before
    its `:stop`, such as a job span in a runner that stops, is never ended,
    and its entry goes with the process.

    A `:stop` or `:exception` with no recorded `:start`, such as one that
    arrives just after `attach/1`, is ignored. Spans open when `detach/1` runs
    are not ended, and their entries stay in their processes until those
    processes exit.

    `:telemetry` runs the handler synchronously in the emitting process.
    """

    @dispatch [:snodo, :server, :dispatch]
    @job [:snodo, :tasks, :runner, :job]

    @events [
      @dispatch ++ [:start],
      @dispatch ++ [:stop],
      @dispatch ++ [:exception],
      @job ++ [:start],
      @job ++ [:stop]
    ]

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

    @doc """
    The `:telemetry` events the handler attaches to.
    """
    @spec events() :: [[atom(), ...], ...]
    def events, do: @events

    @doc """
    Attaches the span handler to `events/0`.

    ## Options

      * `:handler_id` - the `:telemetry` handler ID. Defaults to this module.

    Returns `{:error, :already_exists}` when a handler with the ID is already
    attached.
    """
    @spec attach(keyword()) :: :ok | {:error, :already_exists}
    def attach(options \\ []) do
      :telemetry.attach_many(handler_id(options), @events, &__MODULE__.handle_event/4, nil)
    end

    @doc """
    Detaches the span handler attached with the same `:handler_id`.

    Takes the same `:handler_id` option as `attach/1`.
    """
    @spec detach(keyword()) :: :ok | {:error, :not_found}
    def detach(options \\ []) do
      :telemetry.detach(handler_id(options))
    end

    defp handler_id(options), do: Keyword.get(options, :handler_id, __MODULE__)

    @doc false
    @spec handle_event([atom(), ...], map(), map(), term()) :: :ok
    def handle_event(
          event_name,
          _measurements,
          %{telemetry_span_context: ref} = metadata,
          _config
        ) do
      case List.pop_at(event_name, -1) do
        {:start, @dispatch} -> start_dispatch(ref, metadata)
        {:start, @job} -> start_job(ref, metadata)
        {finish, @dispatch} when finish in [:stop, :exception] -> finish_dispatch(ref, metadata)
        {:stop, @job} -> finish_job(ref, metadata)
        _other -> :ok
      end
    end

    def handle_event(_event_name, _measurements, _metadata, _config), do: :ok

    defp start_dispatch(ref, metadata) do
      parent = parent_context(metadata)

      span =
        :otel_tracer.start_span(parent, tracer(), dispatch_name(metadata), %{
          kind: :server,
          attributes: attributes(metadata, @dispatch_attributes)
        })

      token = :otel_ctx.attach(:otel_tracer.set_current_span(parent, span))
      _previous = Process.put(key(ref), {span, token})
      :ok
    end

    defp finish_dispatch(ref, metadata) do
      case Process.delete(key(ref)) do
        {span, token} ->
          _set = :otel_span.set_attributes(span, attributes(metadata, @dispatch_attributes))
          _status = set_dispatch_status(span, metadata)
          _ended = :otel_span.end_span(span)
          _detached = :otel_ctx.detach(token)
          :ok

        nil ->
          :ok
      end
    end

    defp set_dispatch_status(span, %{reason_class: reason_class}),
      do: :otel_span.set_status(span, :error, attribute_value(reason_class))

    defp set_dispatch_status(span, %{outcome: :error} = metadata),
      do: :otel_span.set_status(span, :error, error_message(metadata))

    defp set_dispatch_status(_span, _metadata), do: false

    defp error_message(%{error_code: code}) when is_integer(code),
      do: "JSON-RPC error " <> Integer.to_string(code)

    defp error_message(_metadata), do: "JSON-RPC error"

    defp start_job(ref, metadata) do
      span =
        :otel_tracer.start_span(:otel_ctx.get_current(), tracer(), "snodo.tasks.runner.job", %{
          kind: :internal,
          attributes: attributes(metadata, @job_attributes)
        })

      _previous = Process.put(key(ref), span)
      :ok
    end

    defp finish_job(ref, metadata) do
      case Process.delete(key(ref)) do
        nil ->
          :ok

        span ->
          _set = :otel_span.set_attributes(span, attributes(metadata, @job_attributes))

          if metadata[:outcome] in @failed_job_outcomes do
            _status = :otel_span.set_status(span, :error, attribute_value(metadata.outcome))
          end

          _ended = :otel_span.end_span(span)
          :ok
      end
    end

    # The dispatch metadata holds only a traceparent that Snodo.TraceContext
    # validated, and a tracestate only alongside one.
    defp parent_context(%{traceparent: traceparent} = metadata) when is_binary(traceparent) do
      carrier =
        case metadata do
          %{tracestate: state} when is_binary(state) ->
            [{"traceparent", traceparent}, {"tracestate", state}]

          _no_state ->
            [{"traceparent", traceparent}]
        end

      :otel_propagator_text_map.extract_to(
        :otel_ctx.get_current(),
        :otel_propagator_trace_context,
        carrier
      )
    end

    defp parent_context(_metadata), do: :otel_ctx.get_current()

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

    defp key(ref), do: {__MODULE__, ref}
  end
end
