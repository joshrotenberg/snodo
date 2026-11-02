# Initialize-era clients

The runtime remains 2026-only by default. Applications can opt into
`Snodo.Protocol.V2025_11_25` and `Snodo.Protocol.V2025_06_18` alongside
`Snodo.Protocol.V2026_07_28`, in that preference order after the latest dialect.
Merely loading a module does not enable it.

## HTTP

`initialize` selects the exact requested enabled legacy version, or the first
configured initialize-capable dialect for an unsupported proposal. Malformed
initialization and conflicting version headers fail. Subsequent requests use
`MCP-Protocol-Version`; missing headers are rejected because the March 2025
fallback dialect is not implemented. Initialization does not require that header.
`notifications/initialized` returns an empty HTTP 202 response. Ping is supported.
JSON-RPC errors from executing a request, such as an
unknown tool or method, are returned with HTTP 200, because clients of these
revisions treat a non-2xx answer as a transport failure and 404 as an expired
session. Admission failures (media type, Origin, a missing or unsupported
`MCP-Protocol-Version`) keep their 4xx statuses. Authentication remains
application owned and is evaluated for each request; session or client metadata
never becomes an identity.

By default the dialects run sessionless: GET and DELETE return 405, and there
is no HTTP session ID, session process, or retained client capability state.
Applications must supply the existing cancellation scope for peers that need
separate request-id namespaces. With the transport's `sessions:` option,
`initialize` starts a `Snodo.Session` and returns `Mcp-Session-Id`, and later
requests must carry it; see [Sessions](#sessions).

## Stdio

Over stdio the version is negotiated once per connection. `initialize` selects
a version as it does over HTTP, and `Snodo.Transport.Stdio` records the version
from the successful result. Every later message on the connection is handled
as if it carried `MCP-Protocol-Version` with that version, so dialect
selection, validation, and result shaping are the same as over HTTP.
`notifications/initialized` gets no reply, and a repeated `initialize`
negotiates again. A request sent before `initialize` carries no version and is
not handled by a legacy dialect. A 2026-07-28 client never sends `initialize`,
so its messages are unaffected. Progress and `notifications/cancelled` work as
they do for 2026-07-28 clients on the same transport. With `sessions: true` the
connection is the client's session, with no ID.

## Shared behavior

The shared router handles tools, prompts, resource lists/templates/reads,
completion and pagination. Legacy wire shaping omits 2026 resultType, cache and
server metadata fields. Legacy structured output and output schemas require an
object. A tool whose input or output schema is not an object is left out of
`tools/list` on these dialects, and a call to it returns -32602 before it runs;
`Snodo.Server.Runtime.new/1` logs a warning naming such tools when a legacy
dialect is enabled. The 2026-07-28 dialect still lists and calls them.
Execution errors retain readable content with isError; protocol errors
remain JSON-RPC errors. Request-bound progress can use SSE; cancellation retains
the executor's authenticated isolation. Tasks are not implemented. Clients may
not send `inputResponses` or `requestState`: on a session the server supplies
them itself.

Configured capabilities must be implemented by at least one enabled profile.
`listChanged` and `subscribe` (with a configured `subscription_source`) are
advertised by `server/discover` for 2026-07-28, and in the `initialize` result
only to a client that gets a session; a sessionless client never receives
those notifications. A surface no enabled dialect implements, such as `tasks`
on an initialize-era-only runtime, still raises at startup.

## Sessions

Sessions are a separate opt-in from the dialects, so enabling 2025-11-25 or
2025-06-18 changes nothing until a transport is also given `sessions:`. The
options, limits, status codes, and the sticky load balancing a multi-node
deployment needs are in the
[transports guide](transports.md#initialize-era-sessions).

On a session:

- A handler's input requests reach the client as server-initiated requests. A
  handler written for 2026-07-28 returns `Snodo.Result.input_required/1` with
  `Snodo.Elicitation`, `Snodo.Sampling`, or `Snodo.Roots` requests; the
  transport sends each one as `elicitation/create`, `sampling/createMessage`,
  or `roots/list` on the request's response stream, and calls the handler
  again with the answers in `Snodo.Context.input_responses`. One handler
  serves both eras. Without a session the result fails with -32603, as before.
- `resources/subscribe` and `resources/unsubscribe` change the resources the
  session watches, and `notifications/resources/updated`,
  `notifications/tools/list_changed`, `notifications/prompts/list_changed`,
  and `notifications/resources/list_changed` carry the runtime's
  `:subscription_source` events. One `Snodo.Subscription.Hub` can feed
  2026-07-28 `subscriptions/listen` streams and initialize-era sessions.
  Without a session these methods answer -32601.
- `logging/setLevel` holds for the rest of the session.
- `notifications/cancelled` cancels a request in flight on the same session,
  over HTTP as well as stdio.
- `Snodo.Context.session` is the session's `Snodo.Session` snapshot, and
  `Snodo.Context.client_capabilities` and `client_info` are the ones the client
  sent with `initialize`.

`Last-Event-ID` resumability is not implemented.

## Official conformance

The official runner's frozen 2025-11-25 requirement set runs in CI against a
fixture with these dialects enabled. With sessions on, all 30 required
scenarios pass, on the native listener and on the Plug. A separate sessionless
lane keeps the default mode gated: 23 of 30 pass there, and the failures are
the server-initiated sampling and elicitation and `resources/subscribe`
scenarios, which need a session, plus a warning that no session ID is issued.
The 2025-06-18 run has no frozen set; with sessions on, all 27 of its scenarios
pass. `logging/setLevel` is implemented; see the [logging guide](logging.md).
See the
[conformance lanes](https://github.com/joshrotenberg/snodo/blob/main/conformance/README.md#additional-server-lanes).

## Snodo.Client as an initialize-era client

`Snodo.Client` speaks these two versions as well as 2026-07-28, so it can call
a server built on an older SDK, or a snodo server configured with only these
dialects. By default `connect/2` probes with `server/discover` and falls back
to `initialize` with 2025-11-25, then 2025-06-18; `protocol:` pins a version.
The negotiated session, the `Mcp-Session-Id` handling, `DELETE` on close, and
the routing of the server's own requests (`elicitation/create`,
`sampling/createMessage`, `roots/list`) to the client's input handlers are
described in the [client guide](client.md#protocol-versions).
Against a snodo server with these dialects, a direct, stdio, or HTTP client
negotiates without any application code: the runtime's registry (direct) or
the probe (stdio and HTTP) picks the version.

## Native client evidence

HTTP loopback checks on 2026-09-21 against a real application server:

- Claude Code 2.1.273 `mcp list` initializes with 2025-11-25, connects, and
  lists tools.
- Codex 0.149.0 initializes with 2025-06-18, lists tools, resources, and
  resource templates, calls a tool, and reads both a fixed resource and a
  templated one.
- A restricted Claude print session uses 2026-07-28 `server/discover` and calls
  the same tool.

Stdio checks on 2026-09-26 against a probe server with these dialects enabled:

- Codex 0.157.1 initializes with 2025-06-18, sends `notifications/initialized`,
  lists tools, and calls a tool.
- Claude Code 2.1.283 sends a 2026-07-28 `server/discover` probe, lists tools,
  and calls the same tool. It does not use these dialects.

These checks show that the implemented workflows work with those clients. They
are not general SDK conformance. The test suite covers literal legacy requests,
shared routing, pagination, rejection cases, mixed-version routing, HTTP
progress, cross-principal cancellation, and stdio negotiation.
