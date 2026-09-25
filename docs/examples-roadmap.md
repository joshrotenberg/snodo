# Examples roadmap and status

Examples 1–22 are implemented. Examples 1–9 and 11–22 run under root
`mix examples`: the root task runs examples 1–6, 12–16, and 18–20 against standalone `snodo`,
delegates examples 07–09 and 17 to the independent `:snodo_tasks` child package, and
delegates example 11 to `:snodo_tasks_sqlite`, and examples 21/22 to the optional
Plug and JSV integration packages. Example 10 is an opt-in
live-database acceptance artifact owned by `:snodo_tasks_postgres`. The set
tells one architectural story: start with the process-free protocol core, add
application-owned state and concurrent transports, then show that optional
behavior can remain outside that core. They are executable acceptance artifacts,
not copies of test fixtures.

## Common contract

Every numbered example:

- runs in an isolated VM; examples 1–6 use
  `mix run examples/NN_name.exs`, examples 07–09 and 17 run through
  `cd extensions/tasks && mix examples`, and example 10 runs through
  `cd extensions/tasks_postgres && mix example.postgres` with
  `SNODO_TASKS_DATABASE_URL` set; example 11 runs through
  `cd extensions/tasks_sqlite && mix example.sqlite`; examples 12–16 and 18–20 run through
  `mix run examples/NN_name.exs`; examples 21/22 use `mix example.plug` and
  `mix example.jsv` from their integration packages;
- supports `--check`, makes its own assertions, prints one short success line, and
  exits non-zero on failure;
- is deterministic: fixed inputs, explicit synchronization instead of sleeps,
  and an OS-assigned port when a socket is required;
- uses only public library APIs and never imports `test/support`;
- owns and cleans up any processes, sockets, or temporary state it starts; and
- remains small enough to read as a focused feature walkthrough.

Root `mix examples` runs every default no-external-service example (1–9 and 11–22)
with `--check` in a fresh Elixir VM, delegates the Tasks and SQLite entries to
their own dependency graphs, and stops on the first non-zero exit. The
PostgreSQL package's separate live lane runs example 10.

## Ordered set

### 1. `01_direct_tools.exs` — process-free tools

**Purpose:** establish the smallest useful server without starting a transport
or framework-owned process.

**Proves:** `Snodo.Tool` and `Snodo.Server` declarations, discovery, deterministic
`tools/list`, direct `tools/call`, and exact result shaping.

**`--check`:** discover the server, assert the single advertised tool and its
schema, call it with a fixed value, and compare the complete response map.

**Status:** implemented and gated.

### 2. `02_structured_schema.exs` — untouched schemas and validation

**Purpose:** show that the framework preserves schema vocabulary while leaving
full JSON Schema enforcement behind a replaceable application boundary.

**Proves:** rich input/output schema preservation, a custom validator,
`structuredContent`, the JSON text compatibility block, and input validation
errors.

**`--check`:** round-trip a schema containing references, composition, and
vendor keys; assert a valid structured result; then assert invalid input becomes
JSON-RPC `-32602` without invoking the handler.

**Status:** implemented and gated.

### 3. `03_context_and_state.exs` — application-owned state

**Purpose:** demonstrate that handlers can use ordinary Elixir state without
turning the framework router into a state owner.

**Proves:** an application-owned `Agent` or ETS table, immutable request
context, preserved vendor metadata, and the sessionless `2026-07-28` model.

**`--check`:** perform a fixed sequence of state-changing calls, assert the
resulting values and observed metadata, and assert `context.session == nil`.

**Status:** implemented and gated.

### 4. `04_stdio_concurrency.exs` — concurrency and cancellation

**Purpose:** make transport-neutral execution policy visible through a real
stdio subprocess.

**Proves:** independent request execution, atomic JSON-line output,
request-scoped cancellation, suppression of a cancelled response, recovery for
a later call, and protocol-only stdout.

**`--check`:** coordinate slow and fast handlers with explicit messages, assert
the fast response arrives first, cancel the slow request and observe no reply,
then assert a follow-up call succeeds and every stdout line decodes as one
protocol message.

**Status:** implemented and gated.

### 5. `05_http_tools.exs` — native Streamable HTTP

**Purpose:** run the same tool runtime through the native HTTP transport with no
change to tool code.

**Proves:** an OS-assigned local listener, discovery/list/call over POST, pinned
header admission, sessionless responses, normal path/method handling, and reuse
of the shared executor. The walkthrough also points to the pinned official
client/conformance probes for external interoperability.

**`--check`:** make live local requests with the required media types and MCP
headers; assert discovery, list, and call responses; assert no session ID is
minted; and assert one missing required header receives the pinned status and
JSON-RPC error.

**Status:** implemented and gated.

### 6. `06_custom_extension.exs` — out-of-tree protocol extension

**Purpose:** prove a vendor can add one negotiated method without editing the
core protocol catalog, router, or dialect module.

**Proves:** extension registration, core and extension collision protection,
server/client capability negotiation, `context.extensions`, custom validation,
dispatch, result shaping, and error shaping.

**`--check`:** register a local example extension, negotiate fixed settings,
call its method, and assert those settings affect the shaped result; also assert
an unnegotiated call is method-not-found and a colliding registration is
rejected before serving requests.

**Status:** implemented and gated.

### 7. `07_tasks_memory.exs` — Tasks on the extension seam

**Purpose:** validate the extension architecture with a substantial optional
feature rather than absorbing Tasks into the core.

**Proves:** an application-owned in-memory task store, create/poll/cancel,
authorization-scoped lookup, and Tasks implemented through the same public
extension contract as the vendor example but compiled in a separate child
package with a one-way dependency on the core.

**`--check`:** drive one task through deterministic states, verify authorization
scope isolates lookup, cancel a second task, and assert both terminal wire
results without polling sleeps.

**Status:** implemented and gated. The Tasks implementation is the independent
`:snodo_tasks` Mix package, uses generic middleware, result, and
transport-policy hooks rather than adding task methods to the core catalog, and
owns its quality, type, contract, and example commands.

### 8. `08_tasks_durable.exs` — local durable recovery

**Purpose:** move from a volatile task runner to restartable execution while
keeping durability and execution policy outside the protocol core.

**Proves:** a JSON-safe work descriptor with a stable idempotency key, an
application work builder that persists only a safe tenant projection, the
application-owned `WorkExecutor` boundary, synced DETS persistence, boot-epoch
claim fencing, and recovery after the original store and runner stop.

**`--check`:** create a task-required tool call, block its first execution,
stop the store before the runner so the claim cannot be gracefully released,
reopen the same DETS file, and let a fresh recovery runner execute the exact
descriptor. Assert the idempotency key and tenant projection are unchanged and
that `tasks/get` returns the completed original tool result.

**Status:** implemented and gated. `Store.Dets` is a dependency-free, local
single-node reference adapter rather than a production distributed database.
Recovery is intentionally at-least-once: fencing prevents a stale attempt from
committing Task state, but applications must use the descriptor's stable
idempotency key to deduplicate external side effects.

### 9. `09_tasks_retry.exs` — persisted retry/backoff

**Purpose:** prove application-requested retry timing is durable execution
policy rather than runner-local timing.

**Proves:** an immutable exact-delay `RetryPolicy` persisted in `Work`, an
explicit `WorkExecutor` retry outcome, store-authoritative claim deferral,
runner replacement during backoff, and stable idempotency identity across
attempts.

**`--check`:** create a required flaky Task, let its first execution request a
retry, wait for the persisted retry time, and stop the original runner. Start a
replacement before the retry is due, prove the store defers its claim without
another execution, advance the fake authoritative clock, then assert the
replacement completes on attempt two with the same descriptor and idempotency
key.

**Status:** implemented and gated. The finite policy bounds committed
application-requested retries; ambiguous hard-crash replays remain
at-least-once and retain the stable deduplication identity.

### 10. `10_tasks_postgres.exs` — application-owned PostgreSQL durability

**Purpose:** show the production-oriented database adapter without making Ecto
or PostgreSQL a dependency of either the protocol core or the Tasks package.

**Proves:** an application-owned ordinary `Ecto.Repo`, explicit migration and
schema readiness check, authorization-scoped PostgreSQL store configuration,
public `tools/call` and `tasks/get` behavior, and Runner execution through a
persisted `Work` descriptor and application-owned `WorkExecutor`.

**`--check`:** create a unique PostgreSQL schema, run the shipped migration,
create a task-required tool call, observe its persisted descriptor at the
executor boundary, release it to complete, and assert the terminal Tasks result
retains both its input and stable idempotency key. Always remove the exact schema
and Repo before exiting.

**Status:** implemented and gated only in the opt-in PostgreSQL live lane. It is
intentionally excluded from root `mix examples`, which remains free of external
services.

### 11. `11_tasks_sqlite.exs` — application-owned embedded durability

**Purpose:** show that the same protocol-first Tasks contract can use a durable
embedded database without adding Ecto or SQLite to either the protocol core or
the Tasks package.

**Proves:** an application-owned file-backed `Ecto.Repo`, explicit migration
and readiness check, authorization-scoped SQLite store configuration, persisted
Work across a Repo/Runner restart, and completion through the public Tasks and
`WorkExecutor` surfaces.

**`--check`:** create an exact temporary SQLite file, run the shipped migration,
start one task-required tool call, retain its serialized Work and stable
idempotency key across a Repo/Runner restart, recover and complete it, then
migrate down and remove the database plus its WAL sidecars.

**Status:** implemented and included in root `mix examples`. It requires no
external service. Its guarantee is durable single-host execution with one
SQLite writer at a time—not PostgreSQL-style row locking, `SKIP LOCKED`, or a
multi-node queue.

### 12. `12_resources.exs` — application-controlled context

**Purpose:** add the first core primitive beyond Tools using shapes required by
the planned `hexpm-mcp` rewrite.

**Proves:** `use Snodo.Resource`, direct and URI-template registrations,
`resources/list`, `resources/templates/list`, `resources/read`, application-owned
template matching, JSON text content, required cache hints, and missing-resource
`-32602` behavior.

**`--check`:** list a static `toolbox://groups` resource and a
`hex://{name}/info` template, read both from deterministic local fixture data,
assert a per-read private cache override, and prove a matched-but-missing package
returns Invalid Params rather than an empty content list.

**Status:** implemented and included in root `mix examples`. It uses no network
access. RFC 6570 inverse matching remains explicitly outside this slice; list
pagination is composed later in example 15 and subscriptions in example 16.

### 13. `13_prompts.exs` — target-shaped guided workflows

**Purpose:** prove the second core primitive beyond Tools with the exact five
guided workflows in the planned `hexpm-mcp` rewrite.

**Proves:** `use Snodo.Prompt`, server registration, deterministic `prompts/list`,
independent prompt-list cache hints, flat required string arguments,
`prompts/get`, and multi-turn user/assistant messages.

**`--check`:** list all five target-shaped prompt definitions, render a
two-argument migration guide, preserve its two-message conversation, and prove
a missing required package name returns Invalid Params with the missing key.

**Status:** implemented and included in root `mix examples`. It uses no network
access. List pagination is composed later in example 15 and
`notifications/prompts/list_changed` delivery in example 16.

### 14. `14_completions.exs` — contextual argument completion

**Purpose:** compose the existing Prompt and Resource definitions through the
released `completion/complete` utility without adding a duplicate registry.

**Proves:** explicit `completion_arguments`, definition-owned `complete/2`
callbacks, normalized `Snodo.Completion` requests, prompt and exact
resource-template references, previously resolved context arguments, truthful
capability advertisement, and bounded `values`/`total`/`hasMore` results.

**`--check`:** complete a package prompt within a selected category, complete a
resource-template version using its resolved package argument, confirm the
server advertises `completions`, and reject an undeclared target argument.

**Status:** implemented and included in root `mix examples`. It uses local
fixture data only. Candidate ranking and authorization remain application-owned;
resource templates still do not imply framework-owned RFC 6570 expansion.

### 15. `15_pagination.exs` — one cursor policy for every list

**Purpose:** make pagination a server execution policy shared by Tools,
Prompts, Resources, and Resource Templates rather than four component APIs.

**Proves:** a runtime-configured page size, router-owned stable ordering,
framework-owned opaque cursors, cache-hint preservation on every page,
`nextCursor` omission on final pages, and method-scoped cursor rejection.

**`--check`:** traverse two entries from each of the four list operations with
a page size of one, assert exact stable order and cache metadata across both
pages, then prove a `tools/list` cursor cannot be used with `prompts/list`.

**Status:** implemented and included in root `mix examples`. It is process-free,
deterministic, and uses no network access. Completion's `total`/`hasMore`
truncation hints remain deliberately separate from list cursors.

### 16. `16_subscriptions.exs` — application-owned event streams

**Purpose:** add long-lived protocol delivery without turning the router or the
generic request executor into a state owner.

**Proves:** an application-owned `Snodo.Subscription.Source`, capability-narrowed
filter negotiation, acknowledgement-before-delivery ordering, framework-owned
subscription metadata, one event in flight, unrequested-event filtering, and a
correlated graceful completion.

**`--check`:** open a subscription requesting tool, prompt, and resource
notifications; assert the advertised source accepts only supported fields;
shape tool-list and exact resource-update events; prove no second pull happens
until the first event is consumed; then close with the original request ID.

**Status:** implemented and included in root `mix examples`. The direct example
keeps the source contract readable; contract tests separately exercise stdio
cancellation/demultiplexing and native long-lived HTTP SSE/disconnect cleanup.

### 17. `17_tasks_subscriptions.exs` — extension-composed task status streams

**Purpose:** prove an independently packaged extension can add filter and event
semantics while reusing the core subscription lifecycle unchanged.

**Proves:** negotiated `taskIds`, store-backed visibility admission,
extension-owned `notifications/tasks` shaping, a complete status snapshot,
shared acknowledgement/pull/backpressure/completion, and no Tasks entry in the
core method profile.

**`--check`:** create a working Task, listen for its ID, pull and shape the
current status through an application source, assert response-only fields are
absent from the notification, and complete the stream.

**Status:** implemented and delegated to `:snodo_tasks` by root `mix examples`.

### 18. `18_subscription_hub.exs` — bounded application event producer

**Purpose:** remove the repeated hand-built source process from ordinary
applications while preserving application ownership of state and change
detection.

**Proves:** an application-supervised `Snodo.Subscription.Hub`, filter-aware
broadcast, a bounded per-listener queue and delivery report, resource-update
helper, fresh read after notification, graceful completion, and cleanup without
router mutation.

**`--check`:** open an exact resource subscription, mutate an application-owned
Agent, publish the corresponding protocol-neutral event through the hub, shape
and correlate the wire notification, read the new resource value, complete the
hub, and assert that no listener remains registered.

**Status:** implemented and included in root `mix examples`.

### 19. `19_instrumentation.exs` — dependency-free lifecycle measurements

**Purpose:** expose operational timing, outcomes, and subscription pressure
without coupling the protocol packages to a metrics implementation.

**Proves:** one fault-isolated `Snodo.Instrumentation` sink configured separately
on the immutable runtime and application-owned hub, dispatch start/stop timing,
stream outcome classification, queue/drop measurements, explicit overflow
policy, and bounded metadata.

**`--check`:** observe a successful list dispatch, open a subscription, publish
twice into a one-event queue, assert the second publication reports and emits a
drop, then observe graceful completion and cleanup.

**Status:** implemented and included in root `mix examples`. Tasks runner/job
and store-transition events are exercised by the independent package suite.

### 20. `20_mrtr_elicitation.exs` — ordinary interactive requests

Implements a read-only preference workflow using public `Snodo.Elicitation`,
`Snodo.Result.input_required/1`, and `Snodo.MRTR.State` APIs across ordinary tools,
resources, and prompts. Demonstrates successive form answers, signed-state
replacement, state-only and input-only continuations, and URL consent without
claiming the external interaction completed. Runs in the default examples gate.

The companion official TypeScript client harness verifies automatic retries over
stdio and native HTTP, fresh request IDs, unchanged operation arguments, and
rejection of request-state reuse on a different operation. See
[the MRTR guide](mrtr-elicitation.md) for security and support boundaries.

## Explicit deferrals

Do not publish examples for progress notifications or authorization yet. Each
would imply a supported public
surface that the spike has not implemented and measured. Add those examples
only after their routing, capability admission, transport behavior, error
shapes, and relevant official conformance lanes are complete. In particular,
authorization should wait for an explicit security model and deployment
guidance rather than presenting a toy middleware check as protocol support.
