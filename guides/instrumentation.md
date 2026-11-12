# Instrumentation

`Snodo.Instrumentation` is a dependency-free, opt-in event sink. It keeps
observability outside protocol semantics and lets an application bridge the
same events to `:telemetry`, OpenTelemetry, Logger, a metrics process, or a
test collector. The `snodo_telemetry` package ships the `:telemetry` bridge
and a handler that turns its events into OpenTelemetry spans; see
[Forwarding to :telemetry](#forwarding-to-telemetry) and
[OpenTelemetry spans](#opentelemetry-spans).

A sink implements one callback:

```elixir
defmodule MyApp.MCPTelemetry do
  @behaviour Snodo.Instrumentation

  @impl true
  def handle_event(name, measurements, metadata, _options) do
    :telemetry.execute(name, measurements, metadata)
  end
end
```

Configure the server runtime, subscription hub, and Tasks runner explicitly:

```elixir
sink = {MyApp.MCPTelemetry, []}

{:ok, hub} =
  Snodo.Subscription.Hub.start_link(
    name: MyApp.SubscriptionHub,
    instrumentation: sink
  )

runtime =
  MyServer.runtime(
    instrumentation: sink,
    subscription_source: Snodo.Subscription.Hub.source(MyApp.SubscriptionHub)
  )

{:ok, runner} =
  Snodo.Extensions.Tasks.Runner.start_link(
    store: store_ref,
    instrumentation: sink
  )
```

The callback is synchronous, matching `:telemetry.execute/3`; applications
should keep it fast and hand expensive work to another process. Callback
faults are caught so they cannot change the observed operation's result. Events
do not include arbitrary request params, auth data, work input, access values,
task results/errors, or input responses. Dispatch events may include the
validated trace fields described below.

Dispatch `method` metadata contains the incoming method only when it is a
string of at most 128 bytes. A missing, non-string, or longer method is
reported as `:invalid` before the request envelope is validated.

When request `_meta` contains a valid W3C `traceparent`, dispatch events include
it as `:traceparent` metadata and include `:tracestate` when that value is valid.
Handlers read the same extracted fields with string keys from
`context.trace_context`; when it contains `"traceparent"`, this map can be passed
as a client's `:trace_context` option. The original values remain in
`context.metadata`. Malformed values do not reject the request and are omitted
from the extracted fields. A `traceparent` over 512 bytes, or a `tracestate`
over 512 bytes or 32 members, is omitted too.
Do not use these identifiers as metric tags; their values vary per request.

Durations use the VM's native monotonic time unit. Convert them with
`System.convert_time_unit(duration, :native, desired_unit)`.

## Event catalog

| Event | Measurements | Metadata |
|---|---|---|
| `[:snodo, :server, :dispatch, :start]` | `system_time` | `method`, `request_id`, `transport`, optional `traceparent` and `tracestate` |
| `[:snodo, :server, :dispatch, :stop]` | `duration` | start metadata plus `outcome`; errors add `error_code` |
| `[:snodo, :server, :dispatch, :exception]` | `duration` | start metadata plus `kind` and bounded `reason_class` |
| `[:snodo, :subscription, :open]` | current `subscriptions` | `request_id`, `transport`, sorted `filter_keys` |
| `[:snodo, :subscription, :publish]` | `matched`, `delivered`, `buffered`, `dropped`, total `queued` | `event_kind`; extension events add `extension_id` |
| `[:snodo, :subscription, :overflow]` | `dropped`, total `queued` | publish metadata plus overflow `policy` |
| `[:snodo, :subscription, :complete]` | current `subscriptions`, total `queued` | none |
| `[:snodo, :subscription, :close]` | remaining `subscriptions` | classified `reason` |
| `[:snodo, :tasks, :runner, :job, :start]` | current `jobs`, `system_time` | `task_id`, `revision`, `source` |
| `[:snodo, :tasks, :runner, :job, :stop]` | `duration`, remaining `jobs` | `task_id`, job `outcome`, `store_outcome`, `release_outcome` |
| `[:snodo, :tasks, :store, :transition]` | `duration` | `task_id`, `expected_revision`, `event_kind`, `authority`, `outcome` |
| `[:snodo, :oauth, :verify, :start]` | `system_time` | none |
| `[:snodo, :oauth, :verify, :stop]` | `duration` | `outcome`: `:ok`, `:missing_token`, `:invalid_token`, `:wrong_issuer`, `:wrong_audience`, `:expired`, or `:insufficient_scope` |
| `[:snodo, :oauth, :verify, :exception]` | `duration` | `kind` and bounded `reason_class` |

The `oauth` events come from the `snodo_oauth` bearer plug when its
`:instrumentation` option is set. They never carry the token or its claims.

The names and bounded metadata are framework API. A particular metrics backend,
aggregation policy, sampling policy, and task-ID cardinality policy remain
application concerns.

## Forwarding to :telemetry

The `snodo_telemetry` package provides `Snodo.Instrumentation.Telemetry`, a
sink that hands every event in the catalog to `:telemetry.execute/3` under the
same name, with the same measurements and metadata. Tooling that consumes
`:telemetry` events, such as `telemetry_metrics`, Phoenix LiveDashboard, and
the OpenTelemetry instrumentations, then sees the events without an
application-written bridge.

<!-- x-release-please-start-version -->
```elixir
{:snodo_telemetry, "~> 0.4.4"}
```
<!-- x-release-please-end -->

Pass the module wherever a sink is accepted:

```elixir
runtime = MyServer.runtime(instrumentation: Snodo.Instrumentation.Telemetry)
```

The sink adds one metadata key. The `:start`, `:stop`, and `:exception`
events of one dispatch or one runner job share a `telemetry_span_context`
reference, as `:telemetry.span/3` emits it, so a handler can pair a stop or
exception with its start. The reference lives in the emitting process between
the two events: nested dispatches in one process form a stack, and runner
jobs, which interleave in the runner process, are keyed by `task_id`. The
subscription and store-transition events are not spans and are forwarded
without the key. Measurements are forwarded unchanged, so `duration` stays in
native time units:

```elixir
[
  Telemetry.Metrics.summary("snodo.server.dispatch.stop.duration",
    unit: {:native, :millisecond},
    tags: [:method, :outcome]
  ),
  Telemetry.Metrics.counter("snodo.server.dispatch.exception.duration",
    tags: [:method, :reason_class]
  ),
  Telemetry.Metrics.last_value("snodo.subscription.publish.queued"),
  Telemetry.Metrics.distribution("snodo.tasks.runner.job.stop.duration",
    unit: {:native, :millisecond},
    tags: [:outcome]
  )
]
```

`:telemetry` runs handlers in the emitting process, inside the dispatch, the
hub call, or the runner, so the advice above about fast callbacks applies to
them too. A handler that raises is detached by `:telemetry`; the observed
operation is not affected.

The opt-in Tasks [contention and soak harness](https://github.com/joshrotenberg/snodo/blob/main/extensions/tasks/stress-testing.md) consumes the
job and transition events directly. Its exact lifecycle invariants illustrate
one way to build correctness evidence without coupling the framework to a
metrics dependency or a machine-specific latency threshold.

## OpenTelemetry spans

`snodo_telemetry` also provides `Snodo.Instrumentation.Telemetry.OpenTelemetry`,
a `:telemetry` handler that starts and ends OpenTelemetry spans from the
dispatch and runner job events of `Snodo.Instrumentation.Telemetry`. The
module is compiled only when the application depends on `opentelemetry_api`.
The application configures the OpenTelemetry SDK and exporter as usual.

```elixir
{:opentelemetry_api, "~> 1.5"},
{:opentelemetry, "~> 1.7"}
```

Configure `Snodo.Instrumentation.Telemetry` as the sink, as above, and attach
the handler once, for example in `Application.start/2`:

```elixir
:ok = Snodo.Instrumentation.Telemetry.OpenTelemetry.attach()
```

Only one span handler can be attached at a time; a second `attach` returns
`{:error, :already_exists}`. `attach` takes one option, `:max_open_spans`,
described below.

| Events | Span name | Kind |
|---|---|---|
| `[:snodo, :server, :dispatch, *]` | the method and the component, such as `tools/call echo`, when a component is named; otherwise `mcp.request`, renamed to the method when the dispatch returns a result | `:server` |
| `[:snodo, :tasks, :runner, :job, *]` | `snodo.tasks.runner.job` | `:internal` |

The method is chosen by the client, so a dispatch span name holds it only
when the server's configuration bounds it, which keeps the number of span
names bounded:

- A component is named for `tools/call`, `prompts/get`, and `resources/read`
  when the router registers the tool, prompt, or direct resource. A component
  the router does not register is reported as `:unknown` and left out of the
  span name, so the requested name never reaches it. A span with a named
  component has its name from the start.
- Otherwise the span starts as `mcp.request` and is renamed to the method
  when the dispatch ends with outcome `:ok` or `:stream`, which only a route
  the server registers can produce.
- A JSON-RPC error, a notification (outcome `:no_reply`), an exception, a
  method reported as `:invalid`, and a dispatch that never ends keep
  `mcp.request`, because any of them can come from a method nothing routes,
  such as one answered with method not found.

The method is always recorded as the `snodo.method` attribute, and
`Snodo.Server` reports a method longer than 128 bytes as `:invalid`. A
sampler sees the name a span starts with.

Span attributes are the event metadata, each under its key with a `snodo.`
prefix, with atoms recorded as strings:

- dispatch: `snodo.method`, `snodo.request_id`, `snodo.transport`,
  `snodo.component`, `snodo.outcome`, `snodo.error_code`, and, for an
  exception, `snodo.kind` and `snodo.reason_class`;
- runner job: `snodo.task_id`, `snodo.revision`, `snodo.source`,
  `snodo.outcome`, `snodo.store_outcome`, and `snodo.release_outcome`.

The events carry no payloads, so neither do the spans. A dispatch span's
status is set to error for a JSON-RPC error response or an exception, with the
error code or the exception class as the message. A runner job span's status
is set to error when the job outcome is `:failed`, `:invalid`,
`:worker_terminated`, or `:max_runtime`.

When request `_meta` carries a valid `traceparent`, the dispatch span's parent
is that remote span, and a valid `tracestate` is kept with it. The remote span
context is built from the fields `Snodo.TraceContext` validated, not parsed
again: the trace flags are kept whole and read as a bit mask, so `03` is
sampled, and a tracestate with W3C Trace Context Level 2 keys such as
`a@b@c` is kept as accepted. Otherwise the parent is the current
OpenTelemetry context of the process that emits the start event, the process
that calls `Snodo.Server.dispatch/3`. Sampling is the SDK's: with its default
parent-based sampler, a `traceparent` whose sampled flag is not set gives an
unrecorded dispatch span.

The stdio, native HTTP, and Plug transports call `Snodo.Server.dispatch/3` in
a task of their executor, a new process whose OpenTelemetry context is empty.
A context held by the connection or request process, such as a span from an
HTTP server instrumentation in front of `snodo_plug`, is not seen there. Under
those transports a dispatch span has a parent only when the client sends a
`traceparent`, and is a root otherwise. When the application calls
`Snodo.Server.dispatch/3` itself, or uses `Snodo.Test.dispatch/2`, in a
process with a current span, that span is the parent.

While the dispatch runs, its span is the current span in that process, and
the previous context is restored when the dispatch ends. A span a handler
starts is a child of the dispatch span only when it is started in that same
process. A component wrapped in `Snodo.Component.Wrap.Timeout` runs in
another task, as does work the handler spawns, so spans started there have no
parent unless the context is passed to them.

Runner job events carry no trace context and are emitted in the runner
process, so a job span is not linked to the dispatch that created the task.
It starts a new trace unless the runner process has a current context, and it
is not made current, because jobs for different tasks interleave in the
runner.

A span's start and its stop or exception must be emitted by the same process,
because the open span is kept there: in one process dictionary entry, a map
keyed by the `telemetry_span_context` reference, which is deleted when no span
is open. `Snodo.Instrumentation` and the Tasks runner both emit each pair from
one process. A stop or exception with no recorded start is ignored.

A dispatch that returns or raises emits a stop or an exception. A dispatch
whose process is killed emits neither: under the stdio, native HTTP, and Plug
transports the executor kills the task on a request timeout, on a
cancellation, and when the connection that owns the request goes away. A job
still running when its runner stops gets no stop either. A span whose process
exits before its stop or exception is never ended by the handler and is not
exported, and its entry goes with the process. The SDK keeps the span until
its span sweeper removes it; with the SDK's defaults the sweeper runs every
10 minutes and drops spans older than 30 minutes without exporting them.

A process holds at most `:max_open_spans` open spans, 1,024 by default. At
the limit a start opens no span, the observed operation is not affected, its
stop is ignored, and the handler emits
`[:snodo, :open_telemetry, :span, :skipped]` with reason `:max_open_spans`.
Every running job of a Tasks runner takes a slot in the runner process, so
keep the limit at or above the runner's `:max_jobs` (32 by default).

```elixir
:ok = Snodo.Instrumentation.Telemetry.OpenTelemetry.attach(max_open_spans: 4_096)
```

The handler never raises, so `:telemetry` never detaches it. The handler's own
preparation (span name, attributes, status message, and the parsed remote
parent) and its calls into the OpenTelemetry API and SDK are isolated
separately, so a raise, throw, or exit is caught and reported with reason
`:handler_failure` or `:sdk_failure`. An SDK failure comes from, for example, a
failing span processor or an SDK that is shutting down; a handler failure
means the event metadata broke its contract or the handler has a bug. At
start, no span is opened and the skipped event is emitted. Ending a span is
three operations, annotate (attributes, name, and status), end, and restore the
previous context; a failing operation emits
`[:snodo, :open_telemetry, :span, :failed]` and the remaining operations still
run, so the previous context is restored.

| Event | Measurements | Metadata |
|---|---|---|
| `[:snodo, :open_telemetry, :span, :skipped]` | `open_spans` in the process | `span`, `operation` (`:start`), `reason` (`:max_open_spans`, `:handler_failure`, or `:sdk_failure`); a failure adds `error_kind` and `error_class` |
| `[:snodo, :open_telemetry, :span, :failed]` | none | `span`, `operation` (`:annotate`, `:end`, or `:restore`), `reason` (`:handler_failure` or `:sdk_failure`), `error_kind`, `error_class` |

`span` is `:dispatch` or `:job`. `error_kind` is `:error`, `:throw`, or
`:exit`. `error_class` is the exception module for `:error`, such as
`RuntimeError` or `ArgumentError` (a raw Erlang error is normalized, so
`:badarg` becomes `ArgumentError`), and `:throw` or `:exit` for those kinds.
The metadata never includes an exception message or a raw reason.

`detach()` stops new spans at once and keeps the handler for stop and
exception events attached, so spans already open are ended and their contexts
restored as usual; a later `attach` reuses it. `detach(open_spans: :abandon)`
removes both handlers: spans open at that moment are never ended, and their
entries, and for a dispatch its current context, stay in their processes
until those processes exit.

The OAuth verification events are not turned into spans.

### Limits

- A dispatch killed on timeout or cancel, and a job still running when its
  runner stops, leave their spans unended and unexported, as described above.
- Under the stdio, native HTTP, and Plug transports a dispatch span's parent
  comes only from a client `traceparent`, and spans started outside the
  dispatching process, including inside `Snodo.Component.Wrap.Timeout`, are
  not its children.
- The SDK sweeper also removes spans that are still open. With its default
  30-minute TTL, a Tasks job that runs longer loses its span, and the job's
  later stop ends nothing. Set the SDK's `:sweeper` `:span_ttl` above the
  longest job's runtime (the runner's `:max_runtime_ms`, one hour by
  default), or set its `:strategy` to `:end_span` so swept spans are ended
  and exported.
- The handler needs `opentelemetry_api ~> 1.5`. It is tested against 1.5
  with the 1.7 SDK. 1.4 is left out: no test runs against it, and its
  `span_ctx` record, from which the handler builds the remote parent, has a
  different layout.
- The `snodo_telemetry` tests always compile the handler. Building the
  package without `opentelemetry_api`, where the handler module is left out,
  is not covered by the tests.
