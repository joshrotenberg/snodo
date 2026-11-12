# Instrumentation events as `:telemetry` events

This package provides `Snodo.Instrumentation.Telemetry`, a
`Snodo.Instrumentation` sink that forwards every event to `:telemetry`. It
adds no runtime dependency to the `snodo` core, and installing it changes no
server until the sink is configured. Tooling that consumes `:telemetry`
events, such as `telemetry_metrics`, Phoenix LiveDashboard, and the
OpenTelemetry instrumentations, then sees the events without an
application-written bridge.

## Use from an application

Add `snodo_telemetry` next to `snodo`:

<!-- x-release-please-start-version -->
```elixir
{:snodo_telemetry, "~> 0.4.4"}
```
<!-- x-release-please-end -->

Then pass the module wherever a sink is accepted: the server runtime, the
subscription hub, and the Tasks runner.

```elixir
{:ok, hub} =
  Snodo.Subscription.Hub.start_link(
    name: MyApp.SubscriptionHub,
    instrumentation: Snodo.Instrumentation.Telemetry
  )

runtime =
  MyServer.runtime(
    instrumentation: Snodo.Instrumentation.Telemetry,
    subscription_source: Snodo.Subscription.Hub.source(MyApp.SubscriptionHub)
  )

{:ok, runner} =
  Snodo.Extensions.Tasks.Runner.start_link(
    store: store_ref,
    instrumentation: Snodo.Instrumentation.Telemetry
  )
```

The sink takes no options.

## What is forwarded

Each event reaches `:telemetry.execute/3` under the name, with the
measurements, and with the metadata that `Snodo.Instrumentation` gives the
sink. The [instrumentation guide](https://hexdocs.pm/snodo/instrumentation.html)
lists every event with its measurements and metadata. No event includes
request params, auth data, work input, access values, task results or errors,
or input responses.

The sink adds one metadata key. The `:start`, `:stop`, and `:exception`
events of a server dispatch or a Tasks runner job share a
`telemetry_span_context` reference, as `:telemetry.span/3` emits it, so a
handler can pair a `:stop` or `:exception` with its `:start`. The reference
is created on `:start` and kept in the emitting process until the matching
`:stop` or `:exception`. Nested dispatches in one process form a stack;
runner jobs, which interleave in the runner process, are keyed by `task_id`.
A `:stop` or `:exception` with no recorded `:start` gets a fresh reference.
Events that are not part of a span are forwarded without the key.

Measurements are forwarded unchanged: `system_time` on `:start`, and
`duration` in native time units on `:stop` and `:exception`. A
`Telemetry.Metrics` definition converts the unit:

```elixir
Telemetry.Metrics.summary("snodo.server.dispatch.stop.duration",
  unit: {:native, :millisecond},
  tags: [:method, :outcome]
)
```

`:telemetry` runs handlers in the emitting process, and `Snodo.Instrumentation`
calls the sink synchronously, so a handler runs inside the dispatch, the hub,
or the runner. Keep handlers fast and hand expensive work to another process.
`:telemetry` detaches a handler that raises; the operation being observed is
not affected.

## OpenTelemetry spans

`Snodo.Instrumentation.Telemetry.OpenTelemetry` is a `:telemetry` handler
that starts and ends OpenTelemetry spans from the dispatch and runner job
events this sink emits. It is compiled only when the application depends on
`opentelemetry_api`, which is an optional dependency of this package. The
application configures the OpenTelemetry SDK and exporter.

```elixir
{:opentelemetry_api, "~> 1.5"},
{:opentelemetry, "~> 1.7"}
```

With the sink configured, attach the handler once, for example in
`Application.start/2`:

```elixir
:ok = Snodo.Instrumentation.Telemetry.OpenTelemetry.attach()
```

- A dispatch becomes a `:server` span named for the method and, when the
  router registers it, the tool, prompt, or direct resource: `tools/call echo`.
  A runner job becomes an `:internal` span named `snodo.tasks.runner.job`.
- Attributes are the event metadata under `snodo.`-prefixed keys, such as
  `snodo.method`, `snodo.component`, `snodo.outcome`, `snodo.error_code`, and
  `snodo.task_id`. No payloads are recorded, because the events carry none.
- A valid `traceparent` in request `_meta`, with its `tracestate`, is the
  dispatch span's parent, built from the fields `Snodo.TraceContext`
  validated: any trace flags, read as a bit mask, and W3C Level 2 tracestate
  keys are kept. Without one, the parent is the dispatching process's current
  context. The dispatch span is current while the dispatch runs, so spans a
  handler starts are its children, and the previous context is restored when
  it ends.
- Runner job events carry no trace context, so a job span is not linked to
  the dispatch that created the task.
- A span's start and its stop or exception must come from the same process,
  which keeps the open span in its dictionary until the matching stop or
  exception. A stop with no recorded start is ignored.
- Only one span handler can be attached; a second `attach` returns
  `{:error, :already_exists}`.

### Limit

| Option | Default | At the limit |
|---|---|---|
| `:max_open_spans` | 1,024 open spans per process | the start opens no span, the operation is unaffected, and `[:snodo, :open_telemetry, :span, :skipped]` is emitted with reason `:max_open_spans` |

```elixir
:ok = Snodo.Instrumentation.Telemetry.OpenTelemetry.attach(max_open_spans: 4_096)
```

Every running job of a Tasks runner takes a slot in the runner process, so
keep the limit at or above the runner's `:max_jobs` (32 by default).

### Failures and detaching

The handler never raises, so `:telemetry` never detaches it. A raise, throw,
or exit is caught and reported as `:handler_failure` (the handler's own
preparation) or `:sdk_failure` (a call into the OpenTelemetry SDK, such as a
failing span processor): at start no span is opened and
`[:snodo, :open_telemetry, :span, :skipped]` is emitted; at the end, a failing
operation emits `[:snodo, :open_telemetry, :span, :failed]` and the remaining
operations, including restoring the previous context, still run. The
diagnostic metadata names the operation and a bounded `error_class`, such as
the exception module, never a message or raw reason.

`detach()` stops new spans and keeps ending the spans already open.
`detach(open_spans: :abandon)` removes the handler entirely; spans open at
that moment are never ended and stay in their processes until those exit.

The module documentation and the
[instrumentation guide](https://hexdocs.pm/snodo/instrumentation.html#opentelemetry-spans)
give the full rules for names, attributes, status, parents, and the
diagnostic events.

## Verification

From this package directory:

```sh
mix deps.get
mix quality
mix quality.types
```

`mix quality` checks formatting, compilation warnings, strict Credo, and the
tests. The tests attach `:telemetry` handlers to every event in the catalog
and check each event's name, measurements, and metadata through a server
dispatch, a subscription hub lifecycle, and a Tasks runner job, including the
shared span context and its absence from point events. Further tests export
the OpenTelemetry spans to the test process with the SDK's `otel_exporter_pid`
and check their names, kinds, attributes, status, parents from a
`traceparent` (including flags `03` and `02`, a future version, and Level 2
and malformed trace fields), restoration of an existing context, the open
span limit, detaching during a dispatch, and the absence of payloads. A test
span processor that raises or exits checks that SDK failures are isolated.
The Tasks extension and the OpenTelemetry SDK are test-only dependencies.
