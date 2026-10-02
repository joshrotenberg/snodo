# Aggregating MCP proxy

`snodo_proxy` serves one MCP endpoint backed by several MCP servers. It connects
to each backend with `Snodo.Client`, merges their tools, resources, resource
templates, and prompts, and routes requests to the backend that owns each item.
It runs alongside `snodo` without changing the core router.

## Install

<!-- x-release-please-start-version -->
```elixir
{:snodo_proxy, "~> 0.4.1"}
```
<!-- x-release-please-end -->

## Start and serve

Start the proxy under your application supervisor, then create a runtime for
the transport you want to expose:

```elixir
children = [
  {Snodo.Proxy,
   backends: [
     [id: "search", target: {:http, "http://127.0.0.1:4001/mcp"}],
     [id: "files", target: {:stdio, "file-server", []}]
   ],
   name: MyApp.Proxy}
]

{:ok, _supervisor} = Supervisor.start_link(children, strategy: :one_for_one)
proxy = Process.whereis(MyApp.Proxy)

runtime = Snodo.Proxy.runtime(proxy, authorization: MyApp.Policy)
{:ok, listener} = Snodo.Transport.StreamableHTTP.Server.start_link(runtime: runtime, port: 4000)
```

Each `target` accepts the same HTTP, stdio, or custom transport form as
`Snodo.Client.connect/2`. `{:direct, runtime}` is available for an in-process
server. `client_options:` passes options to the backend client. The proxy
serves MCP `2026-07-28` to frontends; its backend clients negotiate the
versions their targets support. The frontend listener and its authentication
are application owned. If your application restarts the proxy supervisor itself,
rebuild the runtime and restart its frontend listener with the new proxy PID.
Internal manager or hub restarts keep the same proxy PID.

Backend IDs contain letters, digits, `_`, or `-` and start with a letter.
Names default to `<id>.<backend-name>`; set `prefix:` on a backend to change
that. The proxy rejects duplicate names and exact URI collisions when a backend
is added. Resource URIs
are always exposed as `mcp-proxy://<id>/<original-uri>` to preserve ownership,
including for resource templates. A caller must use the advertised URI when
reading through the proxy. The prefix does not change the backend's own name
or URI.

## Runtime changes and status

```elixir
:ok = Snodo.Proxy.add_backend(proxy, id: "notes", target: {:http, notes_url})
:ok = Snodo.Proxy.refresh_backend(proxy, "notes")
:ok = Snodo.Proxy.remove_backend(proxy, "notes")
status = Snodo.Proxy.health(proxy)
```

`add_backend/2` connects and validates the new catalog before publishing it.
`refresh_backend/2` checks one backend immediately. The proxy also refreshes
on backend list change notifications and probes every backend every 30 seconds
by default. A disconnected backend is retried every second. `health/1` gives
each backend an `:up`, `:degraded`, or `:down` status and its latest error.
Clients can request an aggregate `proxy/health` status if they negotiate the
`dev.snodo/proxy` extension; backend IDs and error details stay in the local
`health/1` API. A failed catalog refresh keeps the last accepted snapshot and
marks the backend degraded.

The proxy forwards tool progress and multi round-trip input responses in the
original request. It forwards backend list changes and resource update
notifications through its subscription hub. Resource links in tool and prompt
content are rewritten when the target is in the merged catalog. Resource
subscriptions are admitted only for exact catalog entries accepted by the
upstream listener and allowed by the configured authorization policy. Both
conditions are checked again before
each update is delivered. Authorization also filters discovery and checks
calls, reads, and gets. The backend's own policy still applies when a request
is forwarded.

## Limits and errors

`max_backends:` defaults to 32 and `max_catalog_items:` to 1,000 across all
backends. `health_interval_ms:` defaults to 30,000. All three are positive
integer options to `start_link/1`; invalid values raise `ArgumentError` at
startup. Adding beyond the backend limit returns `{:error, {:backend_limit,
limit}}`; a catalog beyond the item limit returns `{:error, {:catalog_limit,
limit}}`. Duplicate IDs and catalog names return explicit errors. A backend
that fails to connect or fetch its initial catalog cannot be added. A request
for a removed or unknown component gets a protocol invalid-params error.

Resource templates must use the URI template subset supported by
`Snodo.Resource.Template`; an unsupported backend template is rejected with
`{:unsupported_template, template, reason}`. Resource update forwarding covers
exact resources discovered in the backend catalog. Requests to subscribe to
concrete template instances are not acknowledged because the proxy does not
open demand-driven upstream listeners. Backend subscriptions may be unavailable
on older protocol versions or servers without listen
support. Subscription delivery is bounded by the hub's queue and is not
durable. The proxy does not route completion requests in this package version.
Different templates from one backend can still match the same concrete URI;
that read returns an invalid-params ambiguity error. The proxy does not try to
choose one template's authorization component on the backend's behalf.

## Verify

From this package directory, run `mix deps.get`, `mix quality`, and
`mix quality.types`.
