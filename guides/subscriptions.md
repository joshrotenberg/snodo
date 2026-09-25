# Subscriptions

`subscriptions/listen` opens a request-scoped stream of change notifications:
list changes for tools, prompts, and resources, and updates to specific
resources. Subscriptions are not router state. The application supplies the
events through a source.

## Sources

A `Snodo.Subscription.Source` opens a handle for one listen request, agrees to a
subset of the requested filter, blocks in `next/2` until it has an event, and
closes the handle on cancellation, disconnect, completion, or failure.

The framework:

- writes the required acknowledgement before starting a pull worker;
- never pulls a second event until the previous one is written;
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
cancellation. `Snodo.Client` does not open listen streams yet.

## Extensions

An exact-versioned extension may add filter fields and shape its own events on
the same lifecycle. The Tasks package uses this for `taskIds` and
`notifications/tasks`. See [Extensions](extensions.md).

## Examples

`examples/16_subscriptions.exs` (a hand-written source),
`18_subscription_hub.exs` (the hub), and `17_tasks_subscriptions.exs` (Tasks
status streams, run from `extensions/tasks`).
