# Events extension decision, 2026-11-19

[Issue #428](https://github.com/joshrotenberg/snodo/issues/428) asked for the MCP
Events extension. [SEP-3415](https://github.com/modelcontextprotocol/modelcontextprotocol/blob/main/seps/3415-events-extension.md)
became Final on 2026-11-19. It defines how clients discover event types and
receive occurrences from systems behind an MCP server. It applies to
`2026-07-28` and later. [Upstream merge](https://github.com/modelcontextprotocol/modelcontextprotocol/pull/3415).

## Decision

Defer implementation. Webhook delivery requires a hardened outbound HTTP
client. The core has no Hex runtime dependencies, so the extension belongs in
a sibling package. Adding an eleventh package requires coordinated changes to
release-please, CI, and Hex packaging. The SEP just became Final, and no
official SDK reference implementation was available at the time of this
decision. The proposed [server scenarios](https://github.com/modelcontextprotocol/conformance/pull/521)
and [client scenarios](https://github.com/modelcontextprotocol/conformance/pull/541)
are open. The client PR builds on the server PR and uses a handwritten JSON-RPC
client for its passing example. The official TypeScript SDK tracks support
in an open proposal. [TypeScript SDK #2945](https://github.com/modelcontextprotocol/typescript-sdk/issues/2945).

## Protocol surface

The server advertises `io.modelcontextprotocol/events` in
`server/discover` under `capabilities.extensions`. An empty settings object
enables Events with `listChanged` defaulting to false. The client may declare
the same ID with empty settings in its per-request client capabilities.
Clients only call servers that advertise Events. A server without Events
returns method not found. Each event type advertises its own nonempty subset
of poll, push, and webhook.

| Request | Parameters and result |
|---|---|
| `events/list` | Optional pagination `cursor`. Returns `events` descriptors with name, description, delivery modes, input and payload schemas, optional descriptor metadata, and a result-level `nextCursor` when more pages exist. |
| `events/poll` | Event `name`, `arguments`, optional replay `cursor` and `maxAgeMs`, and optional `maxEvents`. Returns occurrences, a cursor, and fields for truncation, more results, and suggested polling delay (`truncated`, `hasMore`, `nextPollMs`). No registration call is needed. |
| `events/stream` | Event `name`, `arguments`, optional `cursor`, `maxAgeMs`, and suggested `heartbeatMs`. Returns a long-lived stream beginning with `notifications/events/active` with the granted heartbeat interval, cursor, and truncation state. The stream carries event, heartbeat, recoverable error, and termination notifications, with a completion result on server close. |
| `events/subscribe` | Event `name`, `arguments`, webhook `delivery` with HTTPS URL and client-generated secret, optional `cursor`, `maxAgeMs`, and nullable `ttlMs`. Returns a stable `id`, authoritative `refreshBefore`, watermark cursor, truncation state, and optional `deliveryStatus` on refresh. |
| `events/unsubscribe` | Event `name`, `arguments`, and `delivery.url`. Removes the matching webhook registration and returns an empty standard result. |

Results carry `resultType: "complete"`. Occurrences carry `eventId`, `name`,
`timestamp`, and `data`. Poll carries the cursor at result level. Push and
webhook can carry it on the occurrence. An absent or null
replay cursor starts at the current position. Replay is optional, and
`truncated: true` signals skipped events. On Streamable HTTP, named requests
mirror `params.name` in `Mcp-Name` and annotated arguments in `Mcp-Param-*`.

Push uses SSE on the response to the MCP POST, or correlated notifications on
stdio. Notifications use the request ID as their subscription ID. The client
aborts the HTTP stream or sends `notifications/cancelled` on stdio to release
server resources. The Events notification on `subscriptions/listen` announces
catalog changes. Its `eventsListChanged` filter opts in to
`notifications/events/list_changed` when the server advertises that setting.

The client owns the subscription registry, persists cursors, follows poll
hints, reconnects push streams, and refreshes webhook registrations before
the granted deadline. It deduplicates occurrences by `eventId` within a
subscription. The server owns authorization, event production and replay, and
webhook delivery state. A receiver can be the client or a separate gateway.

## Design sketch

Model `snodo_events` under `extensions/events` on `extensions/tasks`, with
its own Mix project, README, tests, and a path dependency on core in this
repository. Keep catalog and poll handlers, push framing, and client helpers
in the sibling. Discovery, polling, and push need no outbound HTTP client
and can ship before webhook support. Add an optional outbound adapter for
webhook delivery. Application-specific feeds and external stores belong in
applications or sibling packages.

Implement `Snodo.Extension` with exact-versioned `methods/0`,
`server_settings/1` for `listChanged`, and `negotiate/2` for declared
settings. The registry currently requires a client declaration before
dispatch. Add a generic way for routes to admit requests based on server
advertisement when their specification makes the client declaration optional.
Use `transport_policy/2` for `Mcp-Name` and SSE policy. Generalize
schema-driven HTTP header validation for event arguments if needed. The
extension owns its routes, so `around_dispatch/4` middleware is unnecessary.

Use `subscription_filter/2` and `shape_subscription_event/3` for catalog
changes. The existing `Snodo.Subscription.Source` opens a filter-scoped
handle, pulls one event at a time, and closes it on cancellation or
completion. `Snodo.Subscription.Hub` provides bounded live fan-out, and
`Snodo.Subscription.Bridge` forwards publications across connected Erlang
nodes through `:pg`. Reuse that lifecycle for push if it can expose gaps and
maintain event-specific filtering and authorization. The Hub queues live
events and the Bridge forwards them. Replay and cursor advancement belong to
the Events source. The current server stream dispatch is specific to
`subscriptions/listen`. A generic request-stream hook would let the sibling
reuse transport writing and cancellation with its own framing and heartbeat.

Model an event source or store behaviour on `Snodo.Extensions.Tasks.Store`,
with an application-owned backend, principal-scoped access, bounded reads,
opaque cursors, and a bounded in-memory implementation. Give webhook
registrations a store contract for atomic refresh, removal, expiry, and safe
watermarks. Long or no-expiry grants require persistence across restarts.
Document defaults for page and replay bounds, payload size, open streams,
registration quotas, TTL, and retry and queue budgets. Give each limit defined
behavior, such as `ResourceExhausted` for quotas and truncation for replay gaps.
Use the SEP's recommended 30-second heartbeat as a starting default. For
webhooks, start with a 256 KiB body limit and five delivery attempts within
15 minutes. Select and document the other defaults when implementing each mode.
Track push streams independently of the ordinary concurrent request cap.

### Webhooks

Require an authenticated MCP principal and permission for the event and its
arguments. Recheck access during delivery. Upsert by principal, callback URL,
event name, and canonical arguments. A null TTL requests no expiry. Omitting
TTL requests the server default, and the server can grant a finite lifetime
in either case. Before delivery, establish endpoint
consent through a signed nonce challenge, configured allowlist, prior
out-of-band verification, or same-origin well-known document. Use HTTPS,
validate resolved addresses on every attempt, connect to a validated address
with the original TLS hostname, and forbid redirects. Apply the same controls
to verification requests and rate-limit them.

Sign event and control POSTs with Standard Webhooks HMAC-SHA256 over the raw
body, message ID, and timestamp. The receiver selects the secret using
`X-MCP-Subscription-Id`, verifies before processing, checks freshness with
a five-minute window, and deduplicates by `webhook-id`. Support client-driven
secret rotation with brief dual signing and keep secrets out of logs. Optional
Ed25519 signatures use a trusted same-origin Server Card key.

Persist or forward accepted deliveries before returning `2xx`. The sender
retries independently with bounded exponential backoff, keeping the message
ID and renewing the timestamp and signature. HTTP 410 and 413 end retries for
that delivery. Track a safe watermark across pending deliveries and signal
gaps or termination with signed control envelopes. Treat event payloads as
untrusted, and apply ordinary MCP authorization to actions they trigger.

## Revisit

Revisit when the applicable conformance scenarios merge and can be pinned,
an official SDK reference implementation is available, or a user requests
Events support. Start with the delivery modes that request or evidence
justifies, and use the pinned server and client scenarios for their respective
wire obligations.
