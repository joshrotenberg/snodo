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

Logger output is redirected away from stdout by default, because stdout carries
only protocol messages.

## Native HTTP listener

```elixir
children = [
  {Snodo.Transport.StreamableHTTP.Server, runtime: MyServer.runtime(), port: 4000}
]
```

A dependency-free listener that binds to `127.0.0.1` by default and serves
`POST /mcp`. It answers one request per connection:

- `application/json` for ordinary results.
- `text/event-stream` when a handler reports progress, and for
  `subscriptions/listen`, with keepalive comments and proxy buffering disabled.
- 405 for GET and DELETE. No session IDs are issued.

It checks media types, the mirrored `MCP-Protocol-Version`, `Mcp-Method`, and
`Mcp-Name` headers, the `Mcp-Param-*` headers for a tool's `x-mcp-header`
arguments (see [Components](components.md#arguments-in-http-headers)), and
`Origin` when present: loopback names by default,
`:allowed_origin_hosts` to change, where an entry with a port
(`"localhost:3000"`) pins the port and an Origin with userinfo is refused.
`:allowed_hosts` additionally requires the `Host` header to name a listed host.
It is off by default, because a reverse proxy commonly forwards the public name.
A client disconnect cancels the request.
Options include `:ip`, `:port`, `:path`, `:request_timeout`, `:read_timeout`,
`:max_header_bytes`, and `:max_body_bytes` (2 MB).

The listener also bounds what clients can hold open:

- `:max_connections` (default 1,024). A connection accepted at the limit is
  closed without being read.
- `:head_timeout` (default 10,000 ms from accept). The request head must be
  complete by then; `:read_timeout` (5,000 ms) still bounds each read.
- `:body_timeout` (default 10,000 ms from the end of the head). The request
  body must be complete by then; `:read_timeout` still bounds each read.
- `:max_subscriptions` (default 256). A `subscriptions/listen` stream over the
  limit is closed at its source and the request gets 503. A slot returns when
  the connection serving a stream exits, including a client disconnect.

`Snodo.Transport.StreamableHTTP.Server.url/1` returns the endpoint URL, which is
useful with `port: 0` in tests.

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
bound a client that keeps sending small DATA frames. See
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

## Examples

`examples/04_stdio_concurrency.exs`, `05_http_tools.exs`, `21_plug_bandit.exs`
(from `integrations/plug`), and `24_client_transports.exs`.
