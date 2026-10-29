# Transports

The server core is synchronous: `Snodo.Server.dispatch/3` runs one JSON-RPC
request in the calling process against an immutable runtime. Transports add
framing, concurrency, cancellation, and delivery around that core.

```text
raw JSON-RPC map
  -> protocol registry and exact profile inspection
  -> selected dialect: context and admission
  -> core operation or negotiated extension route
  -> router callback (tool, resource, prompt, completion)
  -> protocol-neutral result, or an opened subscription
  -> selected dialect: wire and stream shaping
```

## Executor

`Snodo.Server.Executor` is the transport-neutral execution layer: bounded
admission, a bounded queue, deadlines, cancellation tokens, and supervised
worker tasks, with cleanup when the submitting process dies. The stdio adapter
and the HTTP listener use it; an application can inject its own executor.

## Limits on message content

Every transport decodes JSON with the same limits. An integer literal longer
than 64 digits is a parse error (-32700). A request id must be a string of at
most 256 bytes or an integer in the int64 range (-32600 otherwise), and a
`progressToken` must meet the same bounds (-32602 otherwise). These values are
echoed in every response and notification for a request, so an error for a
request whose id is out of bounds carries a null id instead.

Resource template matching is linear in the length of the requested URI, with
no backtracking, so the message size limit bounds it. Templates themselves are
limited to 1,024 bytes and 32 variables when the resource module compiles; see
[Components](components.md#template-shapes).

## Stdio

```elixir
:ok = Snodo.Transport.Stdio.serve(MyServer.runtime())
```

`serve/2` runs until EOF and until admitted requests finish, then returns.
Messages are one JSON object per line. Requests run concurrently, responses are
written atomically, and `notifications/cancelled` stops a request with no late
response. Output escapes non-ASCII characters as JSON `\u` escapes, so the
bytes do not depend on the device's encoding.

Options include `:input` and `:output` devices, `:write_timeout` (default
5,000 ms; a blocked write is terminal), `:max_line_bytes` (default 2,000,000;
a longer message is refused with -32600 before decoding), `:request_timeout`,
and `:executor`. A leading UTF-8 byte order mark is ignored.

Standard input is read in chunks that hold at most `:max_line_bytes` of a line
when the VM runs with `-noinput`, and on OTP 28 and later when stdin is a
socket, as Node.js clients provide. Otherwise the VM holds each line in full
before the limit applies. Clients that start the server with a pipe, as Python
and Erlang clients do, are bounded only with `-noinput`: `elixir --erl -noinput`,
`emu_args` for an escript, or `vm.args` for a release.

An application process can send its own server-to-client notification on an
open stdio connection, for example a vendor hint while the connection is idle.
Enable the method names with `:notification_methods` (default `[]`; each must
start with `notifications/` and not be one the protocol defines), then call
`Snodo.Transport.Stdio.notify(transport, method, params)` with the transport's
pid or `:name`. The frame has no id and goes through the same serialized write
path as responses. A disallowed method or non-map or non-JSON params returns
`{:error, %Snodo.Error{}}` and writes nothing; a closed connection returns
`{:error, :closed}`; a failed or timed-out write is terminal, as for any
output, and returns `{:error, {:output_failed, reason}}`; if the transport
process exits during the call, it returns `{:error, {:transport_down, reason}}`.
There is no queue: callers wait for their own write, each bounded by the call
timeout (default 10,000 ms), and nothing is retried. If the call returns
`{:error, :timeout}`, the caller stopped waiting and it is unknown whether the
frame was written; do not assume it was or was not delivered.

Logger output is redirected away from stdout by default, because stdout carries
only protocol messages.

`sessions: true` makes the connection the session of an initialize-era client;
see [Initialize-era sessions](#initialize-era-sessions).

## Native HTTP listener

```elixir
children = [
  {Snodo.Transport.StreamableHTTP.Server, runtime: MyServer.runtime(), port: 4000}
]
```

Or through the server's generated child spec, which supplies the runtime:

```elixir
children = [
  {MyServer, transports: [{Snodo.Transport.StreamableHTTP.Server, port: 4000}]}
]
```

A dependency-free listener that binds to `127.0.0.1` by default and serves
`POST /mcp`. A connection serves further requests after each complete
response (HTTP/1.1 keep-alive), and closes after an error response, an event
stream, `Connection: close`, or an HTTP/1.0 request. It answers:

- `application/json` for ordinary results.
- `text/event-stream` when a handler reports progress, and for
  `subscriptions/listen`, with keepalive comments and proxy buffering disabled.
- 405 for GET and DELETE at `/mcp`, and no session IDs, unless
  [initialize-era sessions](#initialize-era-sessions) are on.

It checks media types, the mirrored `MCP-Protocol-Version`, `Mcp-Method`, and
`Mcp-Name` headers, the `Mcp-Param-*` headers for a tool's `x-mcp-header`
arguments (see [Components](components.md#arguments-in-http-headers)) for
tools in the router or served by an extension's `tool_input_schema/2`, such
as `Snodo.Proxy`'s merged tools, and
`Origin` when present: loopback names by default,
`:allowed_origin_hosts` to change, where an entry with a port
(`"localhost:3000"`) pins the port and an Origin with userinfo is refused.
`:allowed_hosts` additionally requires the `Host` header to name a listed host.
It is off by default, because a reverse proxy commonly forwards the public name.
A client disconnect cancels the request.
Options include `:ip`, `:port`, `:path`, `:request_timeout`, `:read_timeout`,
`:max_header_bytes` (32 KB, including the final `\r\n\r\n`), and
`:max_body_bytes` (2 MB). Body bytes received with the head count only toward
`:max_body_bytes`.

The listener is unauthenticated unless `:request_gate` is set to a
`{module, options}` implementing `Snodo.Transport.StreamableHTTP.RequestGate`.
The gate sees the parsed method, path, and headers before the body is read. It
can serve a separate route, refuse the request, or return trusted identity for
`Snodo.Authorization`. An invalid result or exception fails closed with 500.
The listener bounds the gate with `:request_gate_timeout`; the gate must also
bound and clean up any external calls it makes. For OAuth bearer tokens and
protected resource metadata, use `Snodo.OAuth.ResourceServer.Native` from
[`snodo_oauth`](https://hexdocs.pm/snodo_oauth).

Binding `:ip` outside loopback logs a startup warning, even with a request
gate: the native listener still serves plaintext HTTP. Bind it privately
behind a TLS reverse proxy, or use `Snodo.Transport.Plug` in an HTTP server
with TLS. Configure authentication with a request gate or in the Plug pipeline.

The listener also bounds what clients can hold open:

- `:max_connections` (default 1,024). A connection accepted at the limit is
  closed without being read.
- `:head_timeout` (default 10,000 ms from accept). The request head must be
  complete by then; `:read_timeout` (5,000 ms) still bounds each read.
- `:keepalive_timeout` (default 5,000 ms). How long an idle connection waits
  for its next request before it closes. The next request's `:head_timeout`
  starts when its first bytes arrive.
- `:max_keepalive_requests` (default 100). The most requests one connection
  serves; the last response carries `Connection: close`.
- `:request_gate_timeout` (default 10,000 ms). A gate that does not return in
  time gets a 504 response.
- `:body_timeout` (default 10,000 ms from the end of the head, or from gate
  admission when a gate is configured). The request body must be read by then;
  `:read_timeout` still bounds each read.
- `:max_subscriptions` (default 256). A `subscriptions/listen` stream over the
  limit is closed at its source and the request gets 503. A slot returns when
  the connection serving a stream exits, including a client disconnect.
- `:drain_timeout` (default 5,000 ms). How long a stopping listener waits for
  open connections; see [Shutdown](#shutdown).

`Snodo.Transport.StreamableHTTP.Server.url/1` returns the endpoint URL, which is
useful with `port: 0` in tests.

### Shutdown

When the listener stops, including when its supervisor shuts it down, it
drains before exiting:

1. The listening socket closes. New connections are refused.
2. A connection whose request head or body is still arriving gets 503 and
   closes. A request read in full before the drain began runs to its response.
3. Each open `subscriptions/listen` stream gets its successful completion
   response, its source is closed with reason `:shutdown`, and the connection
   closes.
4. Connections still open after `:drain_timeout` (default 5,000 ms) are killed.
   Their executor work is cancelled and their subscription sources are closed.
5. An executor the listener started is stopped. An executor passed with
   `:executor` keeps running.

The default drain covers ordinary tool calls and fits, with the rest of an
application's shutdown, inside common stop windows such as Docker's 10-second
default. A platform with a shorter stop window, such as Fly's default 5-second
`kill_timeout`, needs a smaller `:drain_timeout` or a longer platform timeout.
Raise it toward `:request_timeout` when requests run longer and the host allows
a longer stop.

The listener's child spec sets `:shutdown` to `:drain_timeout` plus 5,000 ms so
the supervisor waits for the drain. A child spec that overrides `:shutdown`
must keep it above `:drain_timeout`; a supervisor that kills the listener
earlier skips the rest of the drain. The release or platform that stops the VM
must allow for the drain as well.

## Initialize-era sessions

Clients of the opt-in 2025-11-25 and 2025-06-18 dialects (see
[Initialize-era clients](initialize-era-clients.md)) can have a session. With
one, a handler's input requests reach them as server-initiated
`elicitation/create`, `sampling/createMessage`, and `roots/list` requests, and
`resources/subscribe`, `resources/unsubscribe`, and list_changed notifications
work. Sessions are off by default; without them the dialects run sessionless.
2026-07-28 requests never use a session, whatever the setting.

| Transport | Option |
|---|---|
| Native HTTP listener | `sessions: true`, or a keyword list of `Snodo.Session.Manager` options. The listener starts its own manager. |
| `Snodo.Transport.Plug` | `sessions: MyApp.MCPSessions`, the name of a `Snodo.Session.Manager` the application starts before the HTTP server. |
| Stdio | `sessions: true`. The connection is the session and no ID is issued. |

```elixir
children = [
  {Snodo.Subscription.Hub, name: MyApp.Hub},
  {Snodo.Transport.StreamableHTTP.Server,
   runtime: MyServer.runtime(subscription_source: Snodo.Subscription.Hub.source(MyApp.Hub)),
   port: 4000,
   sessions: [max_sessions: 512, idle_timeout: :timer.minutes(10)]}
]
```

A handler written for 2026-07-28 input requests serves these clients
unchanged. It returns `Snodo.Result.input_required/1`; the transport sends each
input request to the client as a JSON-RPC request on the original request's
event stream (or the stdio connection), waits for the answers, and calls the
handler again with the answers in `Snodo.Context.input_responses` and the
result's `requestState` in `Snodo.Context.request_state`. Every round runs
inside the request's `:request_timeout`, so a server that waits for people to
answer elicitations needs a longer one than the 30-second default. At most 10
rounds run before the request fails with -32603, and a client that answers an input request with an error fails
the request with that error. Cancelling the request, or ending the session,
ends the exchange. A client that did not declare the capability an input
request needs gets -32021, as on 2026-07-28. A 2025-06-18 client receives form
elicitations without `mode`, which that revision does not define.

With a `:subscription_source` on the runtime, `initialize` advertises the
runtime's `listChanged` and `resources.subscribe` settings, and the session
opens the source for them. Over HTTP the events go out on the session's
standalone `GET` stream; an event that arrives while no stream is open is
dropped. A resource the authorization policy does not let the principal read
is not subscribed, and `resources/subscribe` still answers `{}`.

Over HTTP:

| Request | Answer |
|---|---|
| `initialize` | Starts a session and returns its ID in `Mcp-Session-Id` (32 URL-safe base64 characters from `:crypto.strong_rand_bytes/1`). A failed initialization keeps no session. |
| Any other request, notification, or response without `Mcp-Session-Id` | 400 |
| An unknown or expired ID, or a session bound to another principal | 404 with JSON-RPC code -32001. The client initializes again. |
| `MCP-Protocol-Version` that differs from the session's | 400 |
| A JSON-RPC response object | Routed to the server request waiting for it; 202 |
| `notifications/cancelled` | Cancels the named request in flight on the session; 202 |
| `GET` with `Accept: text/event-stream` | The standalone stream, with a keepalive comment every `:subscription_keepalive_ms`. A second one for the same session gets 409. |
| `DELETE` | Ends the session; 200 |

A session is bound to the principal that created it: the auth value a request
gate returns, or the Plug's auth assign. Authentication still runs on every
request, and a request with the session's ID and a different principal is
answered as if the session did not exist. By default the principal is the
`:principal` and `:client_id` of an auth map that has a `:principal` key (the
shape `snodo_oauth` assigns, so a refreshed token for the same subject keeps
the session), and the whole auth value otherwise; the manager's `:principal`
option takes a function to change that.

Limits, each with a default and a defined failure:

- `:max_sessions` (default 1,024). An `initialize` over the limit gets 503.
- `:idle_timeout` (default 1,800,000 ms, 30 minutes). A session with no
  request, answer, or open stream for that long ends, and its ID gets 404.
  `:infinity` keeps sessions until `DELETE` or shutdown.
- One standalone stream per session; a second `GET` gets 409.
- The request's existing bounds apply to each exchange: `:request_timeout`
  across all rounds, `:max_body_bytes` for each answer, and 10 rounds.

A session process runs on the node that handled `initialize`. The manager
finds sessions through a `Snodo.Session.Registry`, `Snodo.Session.Registry.Local`
by default, and the core does not route requests between nodes. A deployment
with more than one node behind a load balancer needs sticky routing that sends
every request carrying a given `Mcp-Session-Id` to the node that issued it;
otherwise a request that lands elsewhere gets 404 and the client starts over.
There is no `Last-Event-ID` replay: a dropped stream loses the events sent
while it was closed, and the client opens a new one with `GET`.

## Component limits

The opt-in wrappers in `Snodo.Component.Wrap` bound individual tools,
resources, and prompts after router checks. They apply to direct, stdio, and
HTTP requests alike. Their defaults are:

| Wrapper | Default | Defined failure |
|---|---|---|
| `Timeout` | `timeout: 5_000` ms | `Component timed out` |
| `Concurrency` | `limit: 32` in-flight callbacks per component and key | `Component concurrency limit reached` |
| `RateLimit` | `limit: 60` calls per `window_ms: 60_000`, `max_keys: 10_000` per component | `Component rate limit reached` or `Component rate key capacity reached` |

All numeric options must be positive integers; an invalid declaration fails
compilation. Concurrency and rate wrappers use one shared bucket by default.
Pass `key: fn context -> ... end` to group by a stable context value such as a
verified principal. The core application owns the counters. Concurrency
permits return when a callback finishes or its process exits. Rate buckets
start with the first call for a key and reset after the configured window;
expired keys are pruned when capacity is needed. Counts reset if the core
application restarts. A rejected rate call consumes no callback work, while
an admitted call counts even if its handler later fails.

The `Timeout` wrapper runs the callback in a supervised task linked to the
request owner. The shared task supervisor admits at most 1,024 concurrent
timeout workers and returns `Component timeout worker unavailable` when full.
It stops a task on timeout or owner termination, but cannot undo external
side effects. The built-ins return tool `isError` results, or
JSON-RPC error -32603 for resources and prompts. If the core application is
not running, they return a defined unavailable error.

## Plug and Bandit

The `snodo_plug` package provides `Snodo.Transport.Plug` for applications that
already run Plug, Bandit, or Phoenix, with their own authentication pipeline,
TLS, and timeouts:

```elixir
children = [
  {Snodo.Server.Executor, name: MyApp.SnodoExecutor, max_concurrency: 32, max_queue: 128},
  {Bandit,
   plug: {Snodo.Transport.Plug, runtime: MyServer.runtime(), executor: MyApp.SnodoExecutor},
   ip: {127, 0, 0, 1},
   port: 4000}
]
```

It supports the same JSON, progress SSE, and subscription SSE lifecycles. Plug
only reveals a disconnect when a write fails, so a request still running after
`:disconnect_probe_ms` (default 5,000) switches to SSE and writes keepalive
comments; a failed write cancels the work. `:max_subscriptions` (default 256)
bounds open subscription streams; the count is held in the executor, so Plugs
that share an executor share it. `:body_timeout` (default 10,000 ms from when
the Plug starts reading) bounds the whole request body and answers 408; a
request that declares `Transfer-Encoding` gets 411 without being read. Over
HTTP/2 the deadline is checked only when an adapter read returns, so it does not
bound a client that keeps sending small DATA frames. `:sessions` names a
`Snodo.Session.Manager` for [initialize-era sessions](#initialize-era-sessions).
See
the [`snodo_plug` documentation](https://hexdocs.pm/snodo_plug) and the
[application stack](application-stack.md) for choosing between the native
listener and Plug.

### Phoenix endpoint

Add `snodo_plug` and Bandit to the Phoenix application's dependencies. Keep the
existing endpoint; start the executor before it in the application supervisor:

```elixir
children = [
  {Snodo.Server.Executor,
   name: MyApp.SnodoExecutor, max_concurrency: 32, max_queue: 128},
  MyAppWeb.Endpoint
]
```

Mount the transport in a dedicated router pipeline. The authentication Plug
must verify the caller, assign trusted identity with
`Plug.Conn.assign(conn, :mcp_auth, %{principal: user.id})`, and send a 401 or 403
response with `halt/1` when access is denied. Do not copy an unverified header
into the assign. A verified client-instance identifier may also be assigned to
`:mcp_cancellation_scope` for cross-request cancellation; distinguish client
instances even when they share a user. The transport does not authenticate
callers itself. For OAuth 2.1 bearer tokens, the
[`snodo_oauth`](https://hexdocs.pm/snodo_oauth) package supplies that plug,
the protected resource metadata document, and a scope policy.

```elixir
pipeline :mcp do
  plug MyAppWeb.Plugs.MCPAuth
end

scope "/" do
  pipe_through :mcp

  forward "/mcp", Snodo.Transport.Plug,
    runtime: MyApp.MCPServer.runtime(),
    executor: MyApp.SnodoExecutor,
    path: "/mcp",
    max_body_bytes: 2_000_000,
    read_timeout: 5_000,
    body_timeout: 10_000,
    request_timeout: 30_000,
    allowed_origin_hosts: ["app.example.com"],
    allowed_hosts: ["app.example.com"]
end
```

Phoenix's `forward` evaluates its options when the router compiles and calls
`Snodo.Transport.Plug.init/1` with them on every request. That works for a
runtime made only of data, as above. Refer to processes by registered name, not
pid: `subscription_source: Snodo.Subscription.Hub.source(MyApp.SubscriptionHub)` with
the hub started as `{Snodo.Subscription.Hub, name: MyApp.SubscriptionHub}`, because a pid
in the options would be the one from compile time. A runtime that holds a
function (an authorization option, a Tasks `scope:` function) cannot be
compiled into the router at all. For such a runtime, build the options once at
startup and forward to a small Plug that reads them:

```elixir
defmodule MyAppWeb.MCPPlug do
  @behaviour Plug

  # Call from MyApp.Application.start/2 before starting the supervisor.
  def configure do
    opts =
      Snodo.Transport.Plug.init(
        runtime: MyApp.MCPServer.runtime(),
        executor: MyApp.SnodoExecutor,
        path: "/mcp"
      )

    :persistent_term.put(__MODULE__, opts)
  end

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts),
    do: Snodo.Transport.Plug.call(conn, :persistent_term.get(__MODULE__))
end
```

```elixir
forward "/mcp", MyAppWeb.MCPPlug
```

Phoenix's `forward` removes the `/mcp` prefix from `conn.path_info` and adds it
to `conn.script_name`, but leaves `conn.request_path` as `/mcp`.
`Snodo.Transport.Plug` compares `path:` with `conn.request_path`, so keep the
full public path in that option. Replace the example hosts with the public host
names used by clients. An Origin header, when present, is checked against
`allowed_origin_hosts`; a value such as `"localhost:3000"` also restricts the
port. This is a host check, not a CORS policy. `allowed_hosts` checks the
request Host header, so include the Host
value your reverse proxy forwards. See the [`snodo_plug` options](https://hexdocs.pm/snodo_plug)
for defaults and response behavior.

The Plug needs the raw request body. Phoenix endpoint plugs run before the
router pipelines, and a generated endpoint commonly runs `Plug.Parsers` there.
Replace that parser plug with a conditional wrapper before `plug MyAppWeb.Router`;
keep the application's existing parser options for all other paths:

```elixir
@parser_opts Plug.Parsers.init(
  parsers: [:urlencoded, :multipart, :json],
  pass: ["*/*"],
  json_decoder: Jason
)

plug :parse_non_mcp
plug MyAppWeb.Router

defp parse_non_mcp(%Plug.Conn{request_path: "/mcp"} = conn, _opts), do: conn
defp parse_non_mcp(conn, _opts), do: Plug.Parsers.call(conn, @parser_opts)
```

Do not add a body parser to the `:mcp` router pipeline. The MCP request
requires `Content-Length`, and a request declaring `Transfer-Encoding` gets 411.

With [Bandit's Phoenix adapter](https://bandit.hexdocs.pm/Bandit.PhoenixAdapter.html),
set endpoint HTTP bounds alongside the transport bounds above. For example,
merge these options into the application's existing endpoint configuration:

```elixir
config :my_app, MyAppWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  http: [
    port: 4000,
    http_1_options: [max_header_length: 10_000, max_header_count: 50],
    http_2_options: [enabled: false],
    thousand_island_options: [
      transport_options: [send_timeout: 5_000, send_timeout_close: true]
    ]
  ]
```

Set connection, header, read, write, and shutdown limits on the endpoint and
reverse proxy as well. The transport's `body_timeout` is checked when an adapter
read returns; under HTTP/2, a client sending small DATA frames can keep that
read open. Disable HTTP/2 on an endpoint serving untrusted MCP clients, as
above, or buffer request bodies at a proxy. Disabling it on the endpoint affects
all routes there. The finite send timeout bounds writes that the transport
cannot interrupt. The [`21_plug_bandit.exs` example](https://github.com/joshrotenberg/snodo/blob/main/examples/21_plug_bandit.exs)
checks the transport without adding Phoenix to this repository's dependencies.

## Other hosts

`Snodo.Transport.StreamableHTTP.prepare/3` admits and decodes a
`Snodo.Transport.StreamableHTTP.Request` without running a handler. It returns
`{:ok, prepared}`, or `{:response, response}` when admission fails. `execute/3`
runs a prepared request and returns a `Response` or a `StreamResponse`. A
different HTTP server can translate its requests into that shape. `handle/3`
runs both steps synchronously.

## HTTP client connections

`Snodo.Client.connect({:http, url}, opts)` keeps up to four pooled requests open
for that client and origin. Extra concurrent requests wait up to their request
timeout for a free connection. Set `:pool_size` to change the cap (default 4),
`:pool_idle_timeout` to change how long an unused connection stays open (default
30,000 ms), and `:pool_max_requests` to retire a connection after a fixed
number of requests (default 100). Each option requires a positive integer.

The client reuses only HTTP/1.1 responses with a complete `Content-Length`
body and no `Connection: close` directive. Event streams, responses framed by
socket close or chunked transfer, malformed responses, and failed requests
close their sockets. Event streams detach from the pool and use a separate
socket while they run. `Snodo.Client.close/1` closes idle connections; active
requests finish on their own sockets. Response-size and page limits apply on
every request, including those sent over reused connections.

## Examples

`examples/04_stdio_concurrency.exs`, `05_http_tools.exs`, `21_plug_bandit.exs`
(from `integrations/plug`), and `24_client_transports.exs`.
