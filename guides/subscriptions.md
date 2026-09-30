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

## Transports

Stdio multiplexes streams on one connection and ends one with
`notifications/cancelled`. HTTP answers with `text/event-stream`, disables proxy
buffering, sends keepalive comments, and treats a closed socket as
cancellation.

## The client

`Snodo.Client.listen/3` opens a stream over the direct client, stdio, and
HTTP. It returns a `Snodo.Client.Subscription` once the acknowledgement
arrives, with the filter the server accepted, and delivers each event to the
owning process as a `{:notification, method, params}` message on demand, with
a bounded buffer in between. See [The client](client.md#subscriptions).

## Extensions

An exact-versioned extension may add filter fields and shape its own events on
the same lifecycle. The Tasks package uses this for `taskIds` and
`notifications/tasks`. See [Extensions](extensions.md).

## Examples

`examples/16_subscriptions.exs` (a hand-written source),
`18_subscription_hub.exs` (the hub), and `17_tasks_subscriptions.exs` (Tasks
status streams, run from `extensions/tasks`).
