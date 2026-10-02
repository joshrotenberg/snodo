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
{:snodo_telemetry, "~> 0.4.1"}
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
shared span context and its absence from point events. The Tasks extension is
a test-only dependency.
