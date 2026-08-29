# Instrumentation

`MCP.Instrumentation` is a dependency-free, opt-in event sink. It keeps
observability outside protocol semantics and lets an application bridge the
same events to `:telemetry`, OpenTelemetry, Logger, a metrics process, or a
test collector.

A sink implements one callback:

```elixir
defmodule MyApp.MCPTelemetry do
  @behaviour MCP.Instrumentation

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
  MCP.Subscription.Hub.start_link(
    name: MyApp.SubscriptionHub,
    instrumentation: sink
  )

runtime =
  MyServer.runtime(
    instrumentation: sink,
    subscription_source: MCP.Subscription.Hub.source(MyApp.SubscriptionHub)
  )

{:ok, runner} =
  MCP.Extensions.Tasks.Runner.start_link(
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
| `[:mcp_ex, :server, :dispatch, :start]` | `system_time` | `method`, `request_id`, `transport` |
| `[:mcp_ex, :server, :dispatch, :stop]` | `duration` | start metadata plus `outcome`; errors add `error_code` |
| `[:mcp_ex, :server, :dispatch, :exception]` | `duration` | start metadata plus `kind` and bounded `reason_class` |
| `[:mcp_ex, :subscription, :open]` | current `subscriptions` | `request_id`, `transport`, sorted `filter_keys` |
| `[:mcp_ex, :subscription, :publish]` | `matched`, `delivered`, `buffered`, `dropped`, total `queued` | `event_kind`; extension events add `extension_id` |
| `[:mcp_ex, :subscription, :overflow]` | `dropped`, total `queued` | publish metadata plus overflow `policy` |
| `[:mcp_ex, :subscription, :complete]` | current `subscriptions`, total `queued` | none |
| `[:mcp_ex, :subscription, :close]` | remaining `subscriptions` | classified `reason` |
| `[:mcp_ex, :tasks, :runner, :job, :start]` | current `jobs`, `system_time` | `task_id`, `revision`, `source` |
| `[:mcp_ex, :tasks, :runner, :job, :stop]` | `duration`, remaining `jobs` | `task_id`, job `outcome`, `store_outcome`, `release_outcome` |
| `[:mcp_ex, :tasks, :store, :transition]` | `duration` | `task_id`, `expected_revision`, `event_kind`, `authority`, `outcome` |

The names and bounded metadata are framework API. A particular metrics backend,
aggregation policy, sampling policy, and task-ID cardinality policy remain
application concerns.

The opt-in Tasks [contention and soak harness](stress-testing.md) consumes the
job and transition events directly. Its exact lifecycle invariants illustrate
one way to build correctness evidence without coupling the framework to a
metrics dependency or a machine-specific latency threshold.
