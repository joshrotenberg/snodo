# Optional Plug / Bandit application stack

`snodo_plug` translates `Plug.Conn` through the existing protocol-first
`Snodo.Transport.StreamableHTTP` adapter. It adds Plug as a dependency to this
package, not to the core. Bandit is a development/test dependency here; an
application chooses and directly depends on its HTTP server.

This first integration supports the current stateless **2026-07-28** dialect.
It does not add legacy sessions, authentication policy, OAuth, or a second
protocol implementation. HTTP admission, JSON-RPC shaping, capability checks,
mirrored headers, and extension dispatch remain in the core adapter.

## Application-owned startup

During this unreleased workspace phase, depend on `snodo_plug` by path and add
`{:bandit, "~> 1.12.5"}` to your application. For example:

```elixir
runtime = MyApp.MCPServer.runtime()

children = [
  {Snodo.Server.Executor,
   name: MyApp.SnodoExecutor, max_concurrency: 32, max_queue: 128},
  {Bandit,
   plug: {Snodo.Transport.Plug, runtime: runtime, executor: MyApp.SnodoExecutor},
   ip: {127, 0, 0, 1},
   port: 4000,
   thousand_island_options: [transport_options: [send_timeout: 5_000, send_timeout_close: true]]}
]

Supervisor.start_link(children, strategy: :one_for_one)
```

The Plug owns `/mcp` by default and returns 404 for other paths. Pass `path:` to
change the exact full request path, or mount it in an application router with a
matching path. It halts after handling a request. An already-halted authentication
rejection is preserved. Place it **before `Plug.Parsers`** or any component that
consumes the raw body. It supports both Content-Length and chunked request bodies.

The immutable runtime is application-supplied; there is no global runtime cache,
hidden listener, or implicit executor. Configure a supervised `Snodo.Subscription.Hub`
or another source in your runtime when advertising subscription capabilities.

## Trusted authentication handoff

Run your authentication Plug first. After verifying credentials and deciding
whether the request is authorized to reach MCP, it may set:

```elixir
conn
|> Plug.Conn.assign(:mcp_auth, %{principal: authenticated_user.id})
|> Plug.Conn.assign(:mcp_cancellation_scope, verified_client_instance_id)
```

`Snodo.Context.auth` receives only that trusted auth assign. The transport does not
copy arbitrary Authorization headers, forwarded headers, or JSON metadata into
identity. It does not authenticate callers itself or reject missing credentials:
your application must do that, normally with an HTTP 401/403 and `halt/1`. The
`:auth_assign` option changes the assign name. Request peer information comes from
the public Plug peer API; trusting a reverse proxy remains application policy.

The second assign is optional. When both it and an auth map are present, valid
`notifications/cancelled` can cancel an ordinary queued/running execution in the
same Plug instance, auth value, and verified client-instance scope. Distinguish
client instances, not just users: independent clients may reuse JSON-RPC IDs.
Never copy an unverified client-chosen header into this scope. The
`:cancellation_scope_assign` option changes the assign name.

Without that scope, cross-request cancellation notifications are accepted but
cannot cancel another request by guessing its ID. Cancellation cannot cross an
auth value even if two callers have the same request ID and scope. Notifications
are validated and handled outside the application-work executor, so saturation
does not prevent cancellation. Duplicate live IDs in a configured scope return
409; excess admitted work returns 503. A cancelled original HTTP request receives
204 with no JSON-RPC body. Active subscription streams currently terminate on
disconnect, source completion/failure, or owner termination, not a later HTTP
cancellation notification after their opening execution has completed.

## Per-component authorization

Admission to the endpoint is not admission to every component. Configure
`authorization:` on the runtime you pass to this Plug and `snodo` applies the
policy inside the router, below this transport, using the same
`Snodo.Context.auth` value the assign above supplies. One policy therefore covers
this binding, the native HTTP listener, stdio, and direct dispatch alike.

Discovery refusals hide components from the list responses. An invocation
refusal is the application's own JSON-RPC error inside a 200 response, because
the request itself was authenticated and admitted; use HTTP 401/403 in the
authentication Plug for the endpoint-level decision. See the core
[application stack notes](../../guides/application-stack.md) for the policy
contract.

## Bounds and lifecycle guarantees

| Option | Default | Meaning |
| --- | --- | --- |
| `request_timeout` | 30,000 ms | Finite queue-plus-execution wait; timeout cancels work and returns 504. |
| `max_body_bytes` | 2,000,000 | Raw-body byte bound before JSON decoding. |
| `read_timeout` | 5,000 ms | Plug body-read timeout per underlying read. |
| `subscription_keepalive_ms` | 15,000 ms | Idle SSE comment-write interval; must be finite and positive. |
| `allowed_origin_hosts` | localhost / loopback | Existing core host-based Origin allowlist, not a full CORS policy. An entry with a port (`"localhost:3000"`) pins the port. |
| `allowed_hosts` | unset (any Host) | When set, the `Host` header must name one of these hosts or the request gets 403. Leave unset behind a proxy that forwards a public `Host`. |

Configure Bandit/reverse-proxy connection counts, header/read limits, timeouts,
TLS, and shutdown policy separately. Executor capacity bounds pending application
work, not the number of accepted HTTP connections or opened long-lived streams.
Subscription event buffering is the source's responsibility; the bundled hub
provides bounded queues. Plug body-read limits are approximate at socket-read
granularity, so this adapter also checks the returned byte count before decoding.
The Plug cannot enforce its request deadline while an adapter is blocked inside
a socket write; keep the server's send timeout finite (the startup example uses
five seconds) and configure equivalent write bounds for another HTTP adapter.

Each admitted request gets a short-lived reply owner. Request return, timeout,
or Plug-process death tears it down and cancels abandoned work. This is necessary
because a Bandit connection process may serve multiple requests. An opened
subscription gets a lifecycle guard tied to that request owner: it closes the
source and stops its blocked pull worker if the owner dies, including the race
between execution completion and stream handoff.

SSE sends acknowledgement first, then one notification per completed source pull,
and a terminal response on graceful completion. It only requests the next event
after writing the previous one. Keepalive comments trigger write-side detection
of idle streaming disconnects. Write errors/exceptions and owner termination
clean up the source.

Ordinary handlers may call `Snodo.Progress.report(context, value, total: total,
message: message)`. With a client-supplied `progressToken`, the first accepted
update switches the response to SSE, subsequent reports are acknowledged after
writing, and the final result/error is the terminal SSE message. Without a token
or any reports the response remains ordinary JSON. Progress streams also send
idle keepalives; a failed write cancels the execution. HTTP status is already 200
after the first progress frame, so later errors are JSON-RPC errors in that stream,
not a second HTTP response. Core progress limits and producer checks still apply.

**Important limitation:** portable Plug APIs do not report an idle client
disconnect while an ordinary handler is silent before its first progress update.
Such work may continue until the finite request deadline, cancellation,
completion, or server-process death.
SSE disconnect detection also depends on the HTTP adapter and operating system
reporting a failed write; keepalive timing is not a strict TCP failure-detection
deadline. This package does not access Bandit socket internals or claim the
native listener's immediate read-side disconnect cancellation. General content
streaming beyond progress is not implemented by this slice.

Source `open/3` and `close/3` must be prompt and resource-safe, as required by the
core source contract. External work must still implement its own timeouts and
idempotency: cancelling a BEAM process cannot roll back a side effect.

## Verification

```sh
cd integrations/plug
ERL_FLAGS='+S 4:4' mix deps.get
ERL_FLAGS='+S 4:4' mix quality
ERL_FLAGS='+S 4:4' mix quality.types
ERL_FLAGS='+S 4:4' mix example.plug
```

The checked-in lock currently resolves Plug 1.20.3 and Bandit 1.12.5. Tests start
real Bandit listeners on ephemeral loopback ports and use literal HTTP requests,
not only Plug test connections. They cover trusted auth, admission, raw-body
limits, ignored legacy session headers, saturated/cross-principal cancellation,
queue deadlines, ordinary owner-death cleanup, and SSE ordering, completion,
keepalive disconnects, and abrupt owner-death cleanup. HTTP/2 and TLS have not yet
received equivalent live acceptance here.

[Example 21](../../examples/21_plug_bandit.exs) demonstrates an application-owned
executor and Bandit listener, ephemeral verified credentials passed through
trusted assigns, a normal tool call, and a finite subscription with cleanup.
It binds only loopback on an OS-assigned port and contacts no public service.

The binding relies on public [Plug body-reading](https://hexdocs.pm/plug/Plug.Conn.html#read_body/2),
[chunk-writing](https://hexdocs.pm/plug/Plug.Conn.html#chunk/2), and
[Bandit configuration](https://hexdocs.pm/bandit/Bandit.html) APIs.
