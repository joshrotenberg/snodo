# Subscriptions

`subscriptions/listen` opens a request-scoped stream of change notifications:
list changes for tools, prompts, and resources, and updates to specific
resources. Subscriptions are not router state. The application supplies the
events through a source.

One request may name at most 1,000 URIs in `resourceSubscriptions`; a longer
list is refused with -32602.

## Sources

A `Snodo.Subscription.Source` opens a handle for one listen request, agrees to a
subset of the requested filter, blocks in `next/2` until it has an event, and
closes the handle on cancellation, disconnect, completion, or failure.

`next/2` may be called for a handle after `close/3` has closed it. When a
stream ends, the framework stops the worker that pulls events and closes the
handle from a different process, so a pull from that worker can reach the
source after the close. Return `:closed` for a closed handle rather than raise
or crash the source process.

The framework:

- writes the required acknowledgement before pulling the first event;
- never pulls a second event until the previous one is written;
- closes the source when the process serving the stream exits for any reason,
  including when it is killed;
- stamps the originating request ID on every message;
- drops core events the client did not ask for;
- sends a terminal response when the source completes.

Configure the source on the server, and advertise `listChanged` or `subscribe`
only when one is installed (the runtime refuses to advertise them otherwise):

```elixir
use Snodo.Server,
  name: "my-server",
  version: "1.0.0",
  subscription_source: {MyApp.ChangeSource, source_options},
  capabilities: %{"tools" => %{"listChanged" => true}}
```

## The hub

Applications that do not need a custom source can supervise
`Snodo.Subscription.Hub` and hand its source to the runtime:

```elixir
{:ok, hub} = Snodo.Subscription.Hub.start_link(name: MyApp.Hub)
runtime = MyServer.runtime(subscription_source: Snodo.Subscription.Hub.source(hub))

Snodo.Subscription.Hub.publish(hub, Snodo.Subscription.Event.tools_list_changed())
```

The hub keeps a bounded, filter-aware queue per listener with an explicit
overflow policy and delivery statistics. It never detects changes or changes the
router; the application publishes when its catalog or resources change.

## Across connected nodes

The hub is local to one node. `Snodo.Subscription.Bridge` forwards events to a
hub on each directly connected Erlang node using OTP
[`:pg`](https://www.erlang.org/docs/27/apps/kernel/pg.html), with no extra package.
Start its child spec on every node that serves subscriptions:

```elixir
children = [
  {Snodo.Subscription.Bridge,
   name: MyApp.SubscriptionBridge,
   scope: MyApp.SubscriptionGroup,
   group: :changes,
   hub_options: [max_buffer: 100, overflow: :drop_oldest]}
]

# Include children in your application's supervision tree.
{:ok, _supervisor} = Supervisor.start_link(children, strategy: :one_for_one)

runtime =
  MyServer.runtime(
    subscription_source: Snodo.Subscription.Bridge.source(MyApp.SubscriptionBridge)
  )

Snodo.Subscription.Bridge.publish(
  MyApp.SubscriptionBridge,
  Snodo.Subscription.Event.tools_list_changed()
)
```

The child spec starts the scope, local hub, and forwarding worker in that order
under a dedicated `:rest_for_one` supervisor. A scope or hub failure restarts
the worker so it rejoins with a live hub. If the hub is manually stopped and
restarted, the worker monitors it and resolves its replacement on the next
publication. Publications while the hub is absent return `{:error, :unavailable}`.

The default `start_scope: :auto` checks whether the scope is already registered
when the bridge starts. If so, the bridge only monitors it and never starts a
replacement. Otherwise it starts and owns the scope, including replacements
after failures. `start_scope: true` always allows starting the scope, which can
race another supervisor restarting it. For a shared scope owned by another
supervisor, start it first. You can set `start_scope: false` explicitly to require
that scope:

```elixir
children = [
  %{id: MyApp.SubscriptionGroup, start: {:pg, :start_link, [MyApp.SubscriptionGroup]}},
  {Snodo.Subscription.Bridge,
   name: MyApp.SubscriptionBridge,
   scope: MyApp.SubscriptionGroup,
   start_scope: false}
]

{:ok, _supervisor} = Supervisor.start_link(children, strategy: :rest_for_one)
```

Use a `:rest_for_one` parent with the scope first and its bridges after it.
When the scope fails, the parent stops the bridges and restarts the scope before
restarting them, so they rejoin with a live scope.

In this mode the bridge never starts or waits for the scope. If it is absent
when the scope child starts, `start_link/1` returns:

```elixir
{:error, {:scope_not_started, scope}}
```

If the scope exits later during startup, `start_link/1` may fail on a later child
or succeed and then restart as usual. The usual supervisor startup and linking
semantics apply. If the scope stays absent after a failure, immediate restart
failures exhaust the bridge supervisor's restart intensity and it exits. The
source configuration resolves the current hub each time a stream opens. Opening
a stream or publishing returns
`{:error, :unavailable}` if the relevant supervisor or child is unavailable or
exits during the call. An event may already have reached listeners when a
publication fails during the call.

Use the same scope and group on every participating node. They default to
`Snodo.Subscription.Bridge.PG` and `{Snodo.Subscription.Bridge, :events}`.
The bridge validates an event through its local hub before forwarding it. The
returned delivery report describes only that local hub. Remote sends have no
acknowledgement. Each node's hub keeps its own bounded per-listener queues,
filters, and overflow policy, configured through `:hub_options`.
`Snodo.Subscription.Source` remains the extension point for applications on
another message bus; they can implement it directly or publish into a local hub.

`:pg` membership converges after nodes connect directly; its view does not
relay membership through an intermediary node. A new bridge can miss events
until peers learn about it. Events published during a network split are not
replayed after reconnection. A node, local scope, or hub restart loses its
in-memory listeners and queued events. Clients should reopen streams and refresh
the affected catalogs or resources. For durable delivery or high event volume,
use an application-owned bus with its own replay and backpressure policy. The
hub's per-listener bound does not bound the forwarding worker's incoming mailbox.

`examples/27_distributed_subscriptions.exs` checks forwarding with two local
hubs and verifies that each hub still filters events.

## Transports

Stdio multiplexes streams on one connection and ends one with
`notifications/cancelled`. HTTP answers with `text/event-stream`, disables proxy
buffering, sends keepalive comments, and treats a closed socket as
cancellation.

## The client

`Snodo.Client.listen/3` opens a stream over the direct client, stdio, and
HTTP. It returns a `Snodo.Client.Subscription` once the acknowledgement
arrives, with the filter the server accepted, and delivers each event to the
owning process as a `{:snodo_subscription, ref, payload}` message on demand,
with a bounded buffer in between. An event's payload is
`{:notification, method, params}`. See [The client](client.md#subscriptions).

## Extensions

An exact-versioned extension may add filter fields and shape its own events on
the same lifecycle. The Tasks package uses this for `taskIds` and
`notifications/tasks`. See [Extensions](extensions.md).

## Examples

`examples/16_subscriptions.exs` (a hand-written source),
`18_subscription_hub.exs` (the hub), `27_distributed_subscriptions.exs`
(`:pg` forwarding), and `17_tasks_subscriptions.exs` (Tasks status streams,
run from `extensions/tasks`).
