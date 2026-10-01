# Instrumentation

`Snodo.Instrumentation` is a dependency-free, opt-in event sink. It keeps
observability outside protocol semantics and lets an application bridge the
same events to `:telemetry`, OpenTelemetry, Logger, a metrics process, or a
test collector. The `snodo_telemetry` package ships the `:telemetry` bridge;
see [Forwarding to :telemetry](#forwarding-to-telemetry).

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
faults are caught so they cannot change the observed operation's result. No
event includes request params, auth data, work input, access values, task
results/errors, or input responses.

Durations use the VM's native monotonic time unit. Convert them with
`System.convert_time_unit(duration, :native, desired_unit)`.

## Event catalog

| Event | Measurements | Metadata |
|---|---|---|
| `[:snodo, :server, :dispatch, :start]` | `system_time` | `method`, `request_id`, `transport` |
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
{:snodo_telemetry, "~> 0.4.0"}
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
