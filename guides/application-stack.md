# Recommended application stack

The current application target is MCP **2026-07-28**, using the official
TypeScript client **2.0.0** as the first interoperability baseline. This is a
tested server-side slice, not a full-conformance or all-host compatibility claim.

## Compose the pieces your application needs

| Package | Responsibility | Application ownership |
|---|---|---|
| `snodo` | Revision admission, routing, results, MRTR, progress, subscriptions, native transports | Tool/resource/prompt definitions, immutable runtime, execution and source supervision |
| `snodo_plug` | Plug HTTP boundary, ordinary progress SSE and subscription streaming | Bandit/server choice, authenticated Plug pipeline, timeouts, TLS/proxy configuration |
| `snodo_jsv` | Optional Draft 2020-12 argument/output validation through JSV | Original schemas, compile-once catalog policy, validation cost limits |
| `snodo_tasks` | Exact-versioned Tasks extension and recoverable work lifecycle | WorkExecutor, store configuration, authorization and idempotency |
| `snodo_tasks_sqlite` / `snodo_tasks_postgres` | Optional transactional Task persistence | Repo, migrations, database operations, backups and deployment topology |

The dependency direction is one-way toward the core. Installing an integration
does not silently start a listener, migrate a database, enable a protocol version,
or replace the application's validator.

For an HTTP application, choose the [Plug/Bandit integration](https://github.com/joshrotenberg/snodo/blob/main/integrations/plug/README.md)
and [JSV backend](https://github.com/joshrotenberg/snodo/blob/main/integrations/schema_jsv/README.md). The native HTTP listener
remains useful for an embedded endpoint, examples, and independent acceptance.
Stdio needs neither Plug nor Bandit. `Basic` is still available when its documented
subset is sufficient; it is not the recommended full-vocabulary validator.

The optional JSV adapter preserves data and advertised schemas: no coercion,
default insertion, atom conversion, remote reference fetching, or casting hooks.
It intentionally rejects references into annotation data and unsupported dialects.
It is **not a sandbox for arbitrary untrusted schemas**. Use an application-owned
compiled catalog for fixed schemas and bound execution. See example
[22](https://github.com/joshrotenberg/snodo/blob/main/examples/22_full_schema_validation.exs) and the package's precise policy.

## Request progress is not a subscription

In an ordinary handler:

```elixir
:ok = Snodo.Progress.report(context, 0, total: 2, message: "Fetching package metadata")
# Perform the first bounded stage.
:ok = Snodo.Progress.report(context, 1, total: 2, message: "Preparing the report")
# Return the usual Snodo.Result after finishing.
```

A client-supplied string/integer `progressToken` enables reporting. Without a
token or transport sink, valid reports are no-ops. Reports belong to the original
request worker, must increase strictly, and are acknowledged after the transport
writes them. Defaults permit one outstanding report, 1,000 updates, a 4 KiB
message, and a five-second acknowledgment wait. A timed-out outstanding report
does not permit unlimited queued retries. An application can decide whether a
reporting error should stop its work; progress delivery is not a durable record.

Stdio serializes complete JSON notifications before the terminal response.
Its `write_timeout` defaults to five seconds: one monitored helper performs each
serialized write while the coordinator waits boundedly. A stalled or failed
write ends the transport and cleans up its work; it never queues unlimited
writers or continues after an ambiguous timed-out write. Cancellation and EOF
handling may wait for that write bound, so this is not an asynchronous writer.
Native HTTP and Plug switch to request-scoped SSE only when a progress update is
written. After HTTP 200/SSE begins, a later typed error is the terminal JSON-RPC
error in that stream, not another HTTP status. With no emitted progress, ordinary
JSON response behavior is unchanged. Cancellation/deadline/disconnect cleanup
closes the sink. General incremental content streaming is outside this slice.

Portable Plug cannot immediately detect a silent client's disconnect before the
first write. Keep finite request and socket-write deadlines; streaming keepalive
failure cancels abandoned work. See its documented lifecycle limits rather than
assuming the native listener's read-side disconnect detection applies everywhere.

The official client's same-read-chunk progress callback race is recorded in
[progress acceptance](https://github.com/joshrotenberg/snodo/blob/main/interop/official_client/PROGRESS.md). Our unpaced wire
test requires all ordered notifications even when that client misses callbacks;
the production server does not add artificial delays to hide this limitation.

The protocol prose requires integer/string tokens while the generated schema's
numeric token branch is broader. Admission follows the prose and rejects a
fractional `progressToken`; progress amounts and totals may still be fractional.

## Authentication and durable work

Authenticate before the MCP Plug and pass only verified identity through the
trusted auth assign. Do not promote JSON metadata or arbitrary request headers
into a principal. Configure per-client cancellation scope when using that
optional adapter feature, since independent clients can reuse JSON-RPC IDs.

Tasks remain opt-in. Persist serializable work descriptors, not closures or
transport context. Scope every Task read/update/subscription to the authenticated
principal, and treat recovery as at-least-once execution. A stable idempotency
key is available; deduplicating external effects is application responsibility.
Status notifications are observations, not a replacement for authoritative
store reads or a durable event delivery guarantee.

## Authorization at the component boundary

Authentication stays in the application's Plug pipeline; only the verified
identity reaches `Snodo.Context.auth`. Authorization over the catalog is a
separate, optional runtime option:

```elixir
MyApp.Server.runtime(authorization: {MyApp.Policy, catalog: MyApp.Catalog})
```

`MyApp.Policy.authorize/4` receives the phase, an `Snodo.Authorization.Component`,
the derived `Snodo.Context`, and the configured options. Return `:ok` or
`{:error, %Snodo.Error{}}`. The router applies the decision before argument
validation and before any tool, prompt, resource, or completion callback, so a
guessed name cannot produce a side effect, and a refusal carries the
application's own error instead of an unknown-name error.

Keep the following in mind when writing a policy:

* It runs on every listed component during discovery and once per invocation,
  so keep it allocation-light and free of network or database calls; pass a
  precomputed catalog through the options instead.
* Discovery refusals are ordinary filtering. Record audit events on the
  `:invocation` branch, which is the actual boundary violation.
* Choose the refusal code. JSON-RPC reserves -32000..-32099 for
  implementation-defined server errors, and `Snodo.Error.authorization/3` builds
  one. Over HTTP an application refusal is a JSON-RPC error inside a 200
  response; HTTP status codes remain the authentication layer's concern.
* Capability advertisement is catalog-wide. A context that can see no tools
  still sees the `tools` capability, because capabilities describe the server.
* Subscription sources are application-owned and receive the same context;
  filter their events yourself.

## Protocol-version support

Only the configured latest dialect is implemented and enabled. A client that
supports only an older MCP era cannot use this server merely by connecting or
changing a header. The registry is an allowlist, not an automatic translator.

Older support would need a separately implemented/tested dialect **and** the
older initialization, capability negotiation, method/result semantics, and
transport lifecycle. A dual-era client may choose the modern path; an
older-only client has no such fallback. Older HTTP sessions were optional, so
legacy support does not automatically require persistent server-side storage.
It does require correct older lifecycle semantics.

Reference: the [2025-11-25 initialization lifecycle](https://modelcontextprotocol.io/specification/2025-11-25/basic/lifecycle)
and [optional HTTP session management](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports).
Adding an older dialect is a separate product decision, not part of this
latest-only application milestone.

## Verification boundaries

The [compatibility matrix](compatibility.md), [protocol evidence](protocol-compliance.md),
and [application readiness plan](https://github.com/joshrotenberg/snodo/blob/main/docs/history/application-readiness-plan.md) keep unit tests,
independent schema checks, real-client acceptance, and external conformance separate.
Local runs do not establish that remote CI has executed. Database deployment,
operational load/soak, authentication policy, HTTP/2/TLS acceptance, deprecated
roots/sampling, and additional MCP hosts require their own evidence.
