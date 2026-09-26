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
comments; a failed write cancels the work. See
the [package README](https://github.com/joshrotenberg/snodo/blob/main/integrations/plug/README.md) and the
[application stack](application-stack.md) for choosing between the native
listener and Plug.

## Other hosts

`Snodo.Transport.StreamableHTTP.prepare/3` and `execute/3` are pure: they take
a `Snodo.Transport.StreamableHTTP.Request` and return a `Response` or a
`StreamResponse`. A different HTTP server can translate its requests into that
shape. `handle/3` runs both steps synchronously.

## Examples

`examples/04_stdio_concurrency.exs`, `05_http_tools.exs`, `21_plug_bandit.exs`
(from `integrations/plug`), and `24_client_transports.exs`.
