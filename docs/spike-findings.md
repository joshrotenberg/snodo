# Spike findings

## Outcome

The local Phase 0–2 implementation supports a process-free router, selected
dialect admission and wire shaping, and concurrent stdio handlers with complete
serialized output lines. A reusable executor now adds bounded concurrency,
bounded queueing, deadlines, and request-scoped cancellation around that pure
core. No request session is created for MCP `2026-07-28`.
The released official TypeScript client 2.0.0 now exercises the implemented
stdio slice in pinned modern mode: discovery, list, call, cancellation, and a
successful call after cancellation. The frozen official server suite now also
exercises the native HTTP fixture. Its honest result is partial: 22/37 exercised
whole scenarios pass, with all 37 attempted.

An exact `MCP.Protocol.Profile` now declares both the complete pinned core-method
catalog and the implemented revision slice. A pure inspector enforces metadata,
method kind, direction, placement, params, and typed method rules before routing.
Known-but-unsupported core methods are distinct from vendor extensions. Literal
contract vectors run through direct and stdio dispatch without using the
dialect's request-construction helper.
`mix mcp.contract` reports those internal checks separately from the official
HTTP server requirements. The raw runner had 25/37 required scenarios without a
failure check, but three missing-fixture or false-positive paths are excluded
from the 22/37 exercised score.

The core Resources slice is now end to end rather than catalog-only.
`resources/list`, `resources/templates/list`, and `resources/read` share the
same protocol-neutral definitions and router across direct, stdio, and native
HTTP dispatch. Static resources and separately listed URI templates can return
text, JSON text, or Base64 blob contents; list and read results carry
conservative cache hints with server defaults and handler overrides. Unknown
URIs fail as `-32602`. Template expansion is intentionally not inferred by the
framework: each application owns the exact matcher for the URI-template
variables it declares.

The core Prompts slice now follows the same protocol-first boundary.
`prompts/list` and `prompts/get` share immutable definitions and router dispatch
across direct, stdio, and native HTTP. Definitions preserve titles, icons,
arguments, and vendor metadata; the router validates the protocol's flat string
arguments and required names before rendering. Messages cover text, image,
audio, embedded-resource, and resource-link content. The frozen upstream runner
passes all five Prompt scenarios, and prompt-list caching completes the caching
scenario without widening the notification claim.

Generic list pagination now sits once in server execution after complete,
deterministically ordered router catalogs are returned. One immutable policy
serves `tools/list`, `prompts/list`, `resources/list`, and
`resources/templates/list`; its opaque cursors are bound to the protocol,
method, page size, and exact catalog fingerprint. Equivalent runtimes therefore
produce reusable cursors without a cursor process, while catalog or policy
changes expire outstanding cursors instead of risking duplicates or gaps.
Every page retains its cache hints, the terminal page omits `nextCursor`, and
literal direct/stdio plus native HTTP evidence proves transport parity.
Completion's bounded `total`/`hasMore` result remains a separate contract.

Execution policy is now outside STDIO. `MCP.Server.Executor` owns its
`Task.Supervisor`, opaque execution references, scope-sensitive keys, bounded
admission, queueing, cancellation, deadlines, and reply-owner cleanup. STDIO
retains framing, connection-local ID tracking and notification classification,
outcome-to-wire mapping, serialized writes, and EOF draining. Native HTTP now
reuses the same executor while owning only request admission, connection scope,
disconnect cancellation, and response translation; either transport can use an
application-owned executor.

The out-of-tree extension seam is now concrete rather than a placeholder.
`MCP.Extension.Registry` installs exact-versioned static routes, rejects the
complete family of core and extension collisions, separates installation from
advertisement, and negotiates the intersection of client/server settings for
each request. Advertised extensions can also receive application-owned options,
wrap core dispatch, and contribute exact-route HTTP policy. The Tasks extension
uses those generic seams for `tools/call` augmentation and its three top-level
methods without changing the core catalog or router.

The package boundary is now exercised rather than aspirational: standalone
`mcp_ex` has 154 tests and 25 core contract groups, while the independently
compiled `:mcp_ex_tasks` child depends one-way on the core and has 80 tests and
10 local contract groups. The optional `:mcp_ex_tasks_postgres` sibling adds 9
database-independent tests plus 14 real-PostgreSQL tests across 7 live evidence
groups. The optional `:mcp_ex_tasks_sqlite` sibling adds 19 file-backed tests
across 7 local evidence groups. Root quality delegates inward without making an
extension package a core dependency; only the PostgreSQL service lane remains
opt-in.

The Tasks package also owns an opt-in deterministic stress harness. Its
many-writer workload proves one compare-and-set winner and one committed event
per Task; its repeated Runner batches use instrumentation to prove balanced
start/stop events, applied lifecycle transitions, terminal completion, expected
peak concurrency, and a zero-job drain. The versioned JSON report separates
these exact invariants from descriptive timings, so slower hardware does not
turn a correct run into a failure.

The Tasks persistence boundary now has volatile Memory, local durable DETS, and
optional PostgreSQL and SQLite adapters. Creation atomically stores the initial
snapshot and a versioned, JSON-safe `Work` descriptor. Finite exact-delay retry
policies are persisted with that descriptor and scheduled from store-assigned
commit time. State changes remain CAS-protected JSON-safe events with
idempotent event-ID replay; runners use generic exact-claim, claim-next,
renewal, release, worker-read, and reaping callbacks. Expired claim generations
fence stale commits, DETS boot epochs make claims immediately recoverable after
local store reopen, PostgreSQL uses database time plus row locks for
independently pooled runners, and SQLite uses database time plus `IMMEDIATE`
single-writer transactions. Recovery is at-least-once, so applications must
deduplicate external effects with the descriptor's stable idempotency key.

Request context is used only to obtain action-scoped opaque access. A
`work_builder` may explicitly project the stable tenant/principal data needed
for recovery, but request authority and transport handles are not persisted.
Accepted input responses and their original requests are stored before local
delivery, making identical recovery replay deterministic. All 35 frozen
alpha.11 Tasks-specific assertions pass. Eight generic runner schema checks
still reject the extension's `CreateTaskResult` as a core `CallToolResult`, so
the external probe remains non-zero and is not promoted to a conformance pass.

The attached document describes `2026-07-28` as the “current direction.” As of
this spike, it is the final GA protocol version. The implemented method subset
therefore targets the final official wire contract rather than provisional
shapes.

## Acceptance evidence

| Claim | Evidence |
|---|---|
| Router needs no process | Direct router and server DSL tests build and dispatch ordinary data. |
| Requests are independently concurrent | 100 caller tasks all enter one barrier handler before any is released. |
| Stdio does not serialize handlers | A later fast request responds before an earlier slow request. |
| Execution is bounded | Executor tests prove a concurrency ceiling, FIFO bounded queue, deterministic overload rejection, deadlines, and capacity recovery. |
| Execution policy is transport-neutral | Executor tests contain no JSON-RPC or STDIO behavior; STDIO accepts an injected executor and leaves its lifecycle application-owned. |
| Stdio output remains valid | 100 admitted calls produce 100 independently decodable JSON lines under the configured concurrency bound; an OS subprocess test also keeps Logger and raw tool IO on stderr while stdout contains one protocol line. |
| Released-client interop works | `@modelcontextprotocol/client` 2.0.0 negotiates the modern era over stdio, decodes the tool list, calls the echo tool, cancels a slow call, and successfully calls again. |
| Frozen official conformance is measured honestly | All 37 required scenarios were attempted; 22 exercised whole scenarios pass. The report retains 89 success, 15 failure, 5 skipped, 2 warning, and 1 info required checks and excludes three unexercised runner no-failure results. |
| Native HTTP is protocol-driven | Pure adapter and live-listener tests cover final-era mirrored headers, Base64 names, origins, media types, status mapping, absent session state, normal 404/405 handling, bounded concurrency, disconnect cancellation, and executor ownership. |
| HTTP reuses the execution layer | The listener admits requests before submitting application work to the same `MCP.Server.Executor` used by stdio. |
| Cancellation is request-scoped | `notifications/cancelled` terminates the target worker, suppresses its response, and leaves another request unaffected. |
| Schemas remain canonical maps | A schema containing `$schema`, `$id`, `$defs`, `$ref`, composition, `unevaluatedProperties`, `x-mcp-header`, unknown nested values, and an array output schema is equal through tool registration, `tools/list`, and JSON encode/decode. |
| Validation is pluggable | A test validator receives the original maps, rejects invalid input as `-32602`, and turns invalid handler output into `-32603`; the dependency-free default is pass-through. |
| `_meta` remains extensible | Reserved and vendor request keys reach the handler unchanged in `Context.metadata`. |
| Modern execution has no session | The handler observes `context.session == nil`. |
| Dialects are externally pluggable | A test-only `2099-01-01` dialect with its own metadata keys coexists with `2026-07-28`, resolves, and shapes a custom method without a core switch or version map edit. |
| Admission is profile-driven | The exact profile supplies all 22 directional core rules plus implementation status, placement, lifecycle, params, capability, transport, and limitation facts; inspection runs before semantic routing. |
| Resources are protocol-first | Direct and template definitions list deterministically; exact and explicitly matched URIs read text, JSON text, and Base64 blobs with cache hints; missing resources fail as `-32602`; direct, stdio, and HTTP paths use the same router. |
| Prompts are protocol-first | Definitions list deterministically with independent cache hints; required flat-string arguments are validated before handlers; multi-turn text, image, audio, embedded-resource, and resource-link messages share direct, stdio, and HTTP routing. |
| Core and extension methods cannot blur | `completion/complete` and `subscriptions/listen` are implemented as profiled core methods, while `com.example/custom` remains an extension candidate; Tasks stays extension-only. |
| Extension routes are genuinely out of tree | Test-only modules register one exact-versioned method, negotiate bilateral settings into `Context.extensions`, and own validation, dispatch, and wire shaping without editing the core profile, dialect, or router. |
| Extension collisions fail at construction | Duplicate IDs, cross-extension collisions, and names colliding with implemented, unsupported, or MRTR-only core rules are rejected before serving. |
| Core operations can be extended without joining the catalog | Ordered, advertised, exact-compatible middleware receives application options and can pass a derived immutable context through an arity-1 continuation; installed-only modules remain inert. |
| Tasks remains protocol-first and out of core | The extension augments `tools/call`, owns `tasks/get` / `tasks/update` / `tasks/cancel`, and contributes `Mcp-Name` policy without adding any Task-specific branch to the profile, router, or HTTP adapter. |
| The package dependency is one-way | Core `mcp_ex` compiles and tests independently; `:mcp_ex_tasks` depends on the core, and optional PostgreSQL and SQLite siblings depend on Tasks. Each owns its quality, type, contract, and example or live-database gates. |
| Task races are atomic | Normative tests repeatedly race completion against cancellation, prove exactly one immutable terminal result, and prove idempotent cancellation after either terminal outcome. |
| Task persistence transitions are explicit | Versioned JSON-safe work, events, and snapshots round-trip; creation stores Task and work atomically; CAS rejects stale revisions; duplicate event IDs replay idempotently; and unchanged events do not append history or advance a revision. |
| Task access is application-scoped | Only `authorize/3` receives `MCP.Context`; it returns opaque access bound to one action, and every included adapter exposes cross-scope reads and mutations only as unknown task ID. |
| Worker authority is narrow | A runner claims work with an unguessable renewable lease restricted to lifecycle events for its exact Task and generation; forged, cross-task, stale-generation, and request-action misuse are rejected. |
| Durable work is application-defined | `Work` records carry a stable idempotency key plus JSON-safe type/input data; `WorkExecutor` resolves them after initial and recovery claims, while `work_builder` makes safe tenant/principal projection explicit. |
| Recovery is fenced and at-least-once | Claim expiry and DETS reopen allow a higher generation to recover work and fence the previous worker; external effects remain application-idempotent rather than exactly once. |
| Retry is durable policy | An immutable finite delay list is stored with Work; explicit retry events atomically schedule from store commit time or terminally exhaust, and restarted runners consult persisted availability using the store's clock. |
| PostgreSQL uses real transaction evidence | An ordinary pooled application Repo proves separate-session exact-claim/CAS/idempotency races, `SKIP LOCKED`, database-time retry/TTL decisions, exact lease fencing, post-update aggregate/event rollback, migration rollback, and hard-Runner recovery. |
| SQLite uses real transaction evidence | An ordinary pooled, file-backed application Repo proves `IMMEDIATE` one-winner claim/CAS races, WAL readers during a held writer, bounded busy behavior, scope concealment, event rollback, database-time retry/TTL decisions, exact lease fencing, migration rollback, and hard-Runner recovery. It explicitly does not claim row locks, skip-locked consumption, parallel writers, or a multi-node queue. |
| Asynchronous state is detached and store-authoritative | Workers receive no request-only authority; accepted input responses and original requests are persisted so identical replay returns the same response without a duplicate input event. |
| TTL cleanup is an explicit adapter policy | Memory, DETS, PostgreSQL, and SQLite reap the whole aggregate at `createdAt + ttlMs` and preserve `nil` TTL records; tests prove that chosen boundary without presenting eager deletion as a universal protocol mandate. |
| Frozen Tasks behavior is externally exercised | All 35 Tasks-specific assertions in the pinned alpha.11 runner pass, while eight generic core-schema failures remain visible as a separate runner limitation. |
| Capabilities do not overclaim routes | Runtime construction rejects unsupported core/custom capability keys, unregistered extension advertisements, and nested `listChanged: true` / `resources.subscribe: true` settings without an application subscription source; discovery projects through the selected profile and compatible extension registry. |
| Subscriptions stay application-owned and bounded | Direct, stdio, and native HTTP tests prove truthful filter acknowledgement, one event in flight, subscription-ID stamping, unrequested-event filtering, response-free stdio cancellation, graceful completion, and HTTP disconnect cleanup without holding a generic executor slot. |
| Contract evidence is independent | Literal `_meta` and wire maps exercise both direct and stdio paths without calling `request_metadata/1`; internal and official evidence remain separate. |
| The core remains socket-optional | Direct, stdio, and extension parity tests need no network socket; separate HTTP listener acceptance tests use only OS-assigned localhost ports. |

## Decisions made by the spike

1. `MCP.Router.dispatch/4` is always synchronous. A caller chooses whether to
   invoke it in a task; the router never returns a task or owns a worker process.
2. The router sees semantic operations such as `:tools_list` and
   `{:tools_call, name}`, never JSON-RPC method strings.
3. `MCP.Server.dispatch/3` is the raw-map/dialect boundary and returns a shaped
   JSON-RPC response (or `nil` for a notification) inside `{:ok, value}`, or an
   opened `MCP.Subscription` inside `{:stream, subscription}`.
4. Duplicate tool names and protocol versions fail loudly.
5. Protocol configurations are closed allowlists. Code loading cannot expand a
   running server's advertised or accepted versions.
6. Context retains the complete request `_meta` map while duplicating reserved
   values into typed fields.
7. Tool/business failures become successful tool results with `isError: true`;
   malformed calls, unknown tools, and crashes are JSON-RPC errors.
8. Static discovery, tool-list, resource-list, resource-template-list, and
   resource-read cache hints default conservatively to `ttlMs: 0` and
   `cacheScope: "private"`, with runtime or handler overrides as appropriate.
9. The optional `MCP.Server.Executor` is transport-neutral. It owns bounded
   admission, FIFO queueing, deadlines, task supervision, opaque execution
   references, scope-sensitive cancellation keys, and abandoned-owner cleanup;
   it knows nothing about JSON-RPC or protocol dialects.
10. Stdio owns framing, output, and connection scope. Cancellation uses both a
    cooperative token in `MCP.Context` and worker termination. The executor
    emits exactly one terminal outcome for each admitted job while it and the
    reply owner remain alive, and suppresses racing late results. Reply-owner
    death intentionally cancels without delivery.
11. JSON Schema validation is a runtime dependency: `MCP.Schema.Validator`
    owns validation while the framework only maps input/output failures to the
    correct protocol boundary. No incomplete validator is presented as
    standards-compliant.
12. `MCP.Protocol.Profile` is both the complete exact-revision catalog and the
    implementation support ledger. A dialect's `version/0` and `era/0`
    accessors must agree with it, and standard capabilities are admitted from
    implemented rules only. Extension installation, server advertisement,
    version compatibility, and per-request bilateral negotiation are separate
    gates.
13. Internal contract checks, unsupported surfaces, unmeasured surfaces, and
    official passes are distinct evidence buckets. Internal success never
    becomes an official conformance score.
14. Extension-owned routes handle top-level client-to-server requests only and
    cannot capture a core name. Separate generic middleware may augment a core
    operation, and exact extension routes may add transport policy; neither
    mechanism edits the core catalog.
15. Tasks uses an application-owned store and runner. Creation atomically makes
    the Task and serializable work descriptor visible before the handle is
    returned, task work outlives the initiating request, and
    cancellation/completion race through revisioned events rather than
    application closures executed inside the store.
16. Store authority is deliberately split. Fresh request context produces
    action-scoped opaque access; asynchronous lifecycle work uses a renewable,
    task-and-generation-bound opaque lease. A work builder can project the
    minimum stable application identity required for recovery without retaining
    the request context.
17. Task recovery is at-least-once. Claim generations fence stale framework
    commits, while application executors use the stable work idempotency key to
    make externally visible effects safe to replay.
18. Resource definitions remain protocol-neutral. Exact URIs are routed
    directly; URI templates are advertised as templates but matched only by an
    explicit application callback. The framework does not claim a generic
    RFC 6570 inverse matcher, and ambiguous matches fail closed.

## Final 2026-07-28 details pinned by tests

- Requests require `_meta["io.modelcontextprotocol/protocolVersion"]` and
  `_meta["io.modelcontextprotocol/clientCapabilities"]`.
- Known request metadata and capability fields are type-checked, while unknown
  valid `_meta` and capability values remain intact.
- `clientInfo` is optional but supported, including icons and empty string
  names/versions permitted by the wire schema.
- Every ordinary successful result carries `resultType: "complete"`; Tasks
  creation uses `"task"`, and MRTR input uses `"input_required"`.
- `server/discover` returns `supportedVersions`, capabilities, and mandatory
  cache hints.
- `tools/list` is deterministic and carries mandatory cache hints.
- `resources/list` and `resources/templates/list` are deterministic, separate
  inventories with mandatory cache hints; cursor-bearing requests are rejected.
- `resources/read` validates an absolute URI, returns exactly one or more text
  or Base64 blob content objects, and carries mandatory cache hints.
- An unknown resource URI is an invalid-params error (`-32602`), not an empty
  successful read or a method-not-found error.
- Successful tool calls always carry a `content` array; structured results also
  carry `structuredContent` and a JSON text compatibility block.
- Server identity is stamped under
  `_meta["io.modelcontextprotocol/serverInfo"]`.
- Unsupported versions use `-32022` and include exact `requested` / `supported`
  data.
- JSON-RPC batches are rejected.
- Request and cancellation IDs admit only strings and integers, matching the
  pinned wire schema; floating-point IDs are rejected.
- Errors that cannot be correlated to a readable request carry an explicit
  JSON `null` ID.
- Pagination cursors are opaque, method- and catalog-scoped; malformed cursors
  are invalid params and stale catalog/policy cursors are explicitly expired.
- Stdio cancellation is the metadata-free `notifications/cancelled`
  notification and produces no response.
- The pinned core catalog has 21 unique method strings and 22 directional rules;
  `notifications/cancelled` has separate client-to-server and server-to-client
  support states, while three request-shaped MRTR inputs are never top-level RPCs.

## Architecture validation questions

| Question from the design | Spike answer |
|---|---|
| Can a dialect be added out of tree? | **Yes**, proven with the future dialect fixture. |
| Can an extension add methods and shaping out of tree? | **Yes.** A test-only extension proves exact-versioned registration, bilateral negotiation, validation, dispatch, result/error shaping, callback isolation, DSL installation, and direct/stdio parity. |
| Can applications expose Resources without transport-specific handlers? | **Yes.** One definition/router boundary drives deterministic list/template discovery and exact or explicitly matched reads across direct, stdio, and HTTP dispatch. |
| Can applications expose Prompts without transport-specific handlers? | **Yes.** One prompt definition/render boundary drives cached discovery, required argument checks, and multi-content messages across direct, stdio, and HTTP dispatch. |
| Can a transport avoid protocol-version policy? | **Yes for execution and application routing.** Stdio and HTTP share the executor and server core. Each transport still owns its actual framing/admission, connection scope, cancellation signal, and response delivery. HTTP-specific protocol requirements remain data declared by the selected dialect. |
| Can legacy sessions avoid changing component APIs? | **Not yet tested.** |
| Can Tasks avoid core changes? | **Yes.** The independently compiled child package uses generic middleware, wire-result, extension-route, options, and HTTP-policy seams; Task method names remain absent from the core profile and router, and the core has no dependency on `:mcp_ex_tasks`. Its optional PostgreSQL and SQLite siblings depend inward on Tasks without introducing Ecto into either protocol package. |
| Can MRTR suspend/resume without blocking shared processes? | **Yes for mid-task input.** Task workers park independently while the runner remains responsive, including two simultaneous inputs and partial fulfillment. A general framework MRTR API remains deferred; the frozen pre-task MRTR-to-Task composition fixture also passes. |
| Can 1,000 requests avoid a central serialization bottleneck? | **Not yet proven at 1,000.** Tests show 100 handlers are not serialized and execution is bounded, but admission still passes through one executor coordinator and no benchmark exists. |
| Do arbitrary schema and `_meta` keys survive? | **Yes.** Preservation and a custom validation seam are tested; a bundled full validator is deferred. |
| Can the protocol core be tested without sockets? | **Yes.** Direct, stdio, and extension parity remain socket-free; the native listener has a separate localhost acceptance lane. |
| Can applications own their state model? | **Yes.** The barrier fixture uses caller-owned process state; context is never mutated. |
| Is full official `2026-07-28` server conformance measured? | **Partially.** All 37 frozen scenarios were attempted through native HTTP; 22 exercised whole scenarios pass, so full-revision conformance is not claimed. |

## Deliberate limitations

- No JSON Schema engine is bundled. Production deployments must configure a
  validator with complete 2020-12 support and external `$ref` fetching disabled
  by default; otherwise the pass-through validator performs no instance checks.
- Pagination is stateless and shared by `tools/list`, `prompts/list`,
  `resources/list`, and `resources/templates/list`. It deliberately does not
  promise snapshot isolation across catalog changes; scoped cursors expire when
  the ordered catalog or page policy changes.
- Resource URI templates require an application-supplied matcher. Generic RFC
  6570 inverse matching is deliberately not claimed. Resource subscription and
  list-change wire events are implemented. Applications still detect and
  publish changes; the optional application-supervised subscription hub can
  retain a bounded event backlog.
- Tool, Prompt, and Resource list-change notification shaping is implemented
  only inside an acknowledged subscription. The framework does not invent
  change events from router mutations.
- The executor provides global concurrency and queue limits plus deadlines, but
  has no per-peer fairness, adaptive load shedding, queue-wait deadline, or
  automatic sampling yet. Dependency-free instrumentation now exposes dispatch
  timing and outcomes for application-owned aggregation.
- Extension-owned routes remain limited to top-level client-to-server requests.
  Generic middleware now augments core operations, but extension notifications,
  outbound calls, and a general embedded MRTR API require more infrastructure.
- `Store.Dets` remains a local durable reference: its GenServer serializes
  operations within one BEAM, DETS has a 2 GB file limit, and it does not
  coordinate claims across nodes. The optional SQLite sibling adds an
  application-owned embedded database, but remains local to one host and one
  writer; WAL is not a network-filesystem or multi-node queue mechanism.
  Multi-node persistence is instead isolated in the optional
  `:mcp_ex_tasks_postgres` sibling, which uses database-clock leases, row locks,
  and `FOR UPDATE SKIP LOCKED`. The memory harness supplies a repeatable common
  contention baseline, but both database stores still need production soak,
  upgrade, and operational benchmarking before a release claim.
- The included stores choose to delete an entire aggregate at its
  creation-based TTL boundary, including active work, and never automatically
  reap `ttlMs: nil`. This is an allowed server cleanup policy, not a universal
  Tasks protocol mandate.
- Task recovery is at-least-once rather than exactly once; applications must
  deduplicate externally visible effects with `Work.idempotency_key`.
- Tasks status delivery now reuses `subscriptions/listen`; applications own the
  publication mechanism that feeds store/domain changes into the configured
  source and may use the generic bounded hub without adding Tasks knowledge to
  core.
- An executor can be injected and shared. Subscription open work uses it, while
  active streams move to dedicated pull workers; an application-level
  supervision and load-shedding policy across many transports still needs
  production evidence.
- Stdio's optional default-Logger redirection is VM-global. It is correct for
  the normal single stdio server, but multiple embedded stdio adapters do not
  yet coordinate or restore Logger handler ownership.
- Native Streamable HTTP enforces the current JSON request/response, method,
  header, origin, path, and sessionless policy and streams subscriptions over
  SSE. General non-subscription response streaming and listener-wide graceful
  draining remain deferred.
- The released official TypeScript client passes the checked stdio method
  subset. The separate official server run passes 22/37 exercised whole
  scenarios and therefore does not support a full-revision conformance claim.
- The frozen runner supplies generic wire-schema validation, but its core
  `CallToolResult` branch does not admit the extension-defined
  `CreateTaskResult`. The eight resulting Tasks probe failures remain visible;
  internal literal vectors are not used to erase them.

## Recommended next spike

The default eighteen executable walkthroughs, the Resources, Prompts,
Completion, shared Pagination, Subscription, bounded Producer, and
Instrumentation slices, the
independent Tasks package, its persisted retry/backoff policy, and both optional
Ecto siblings are now implemented. Their ordinary pooled transactions prove
lease fencing, database-time retry/TTL decisions, rollback, and hard-Runner
recovery; SQLite adds no-service embedded single-writer evidence, while the
PostgreSQL setup walkthrough remains opt-in because it requires a database
service.

The independent Tasks extension now contributes its authorized `taskIds`
filter and complete `notifications/tasks` status events without teaching the
core profile about Tasks. The generic seam retains per-extension filter
ownership and reuses the source, transport, cancellation, backpressure, and
completion lifecycle. Applications remain responsible for publishing domain
changes into their chosen source; the Tasks Runner deliberately does not impose
a PubSub system. The optional `MCP.Subscription.Hub` now supplies filter-aware
broadcast, bounded per-listener queues, explicit overflow policy, publication
reports, and core-event helpers without making the immutable router a state
owner. Applications still decide what constitutes a domain or registry change.

Dependency-free, fault-isolated instrumentation now covers dispatch timing and
outcomes, subscription lifecycle/delivery/overflow, Tasks job lifecycle, and
runner-issued store transitions. Its bounded metadata excludes request, auth,
work, access, result, error, and input-response payloads. A deterministic
Memory-store contention and Runner-soak harness now consumes those events and
emits a versioned human or JSON report. It proves correctness and lifecycle
balance without presenting local timings as a capacity claim. A checked-in
BEAM/PostgreSQL matrix and genuine version-one-to-two migration chain now make
compatibility and data-preserving rollback executable; unrun CI combinations
remain policy rather than claimed evidence. The next bounded slice is the
`hexpm-mcp` target-application rewrite, using only the public framework and
extension APIs to expose integration friction before release packaging.
Raise the frozen
official core score from its measured 22/37 baseline only by adding real
fixtures and framework surfaces; preserve the checked-in exclusion reasons so
missing fixtures and warning-only behavior never become claimed passes. A
general MRTR API and a legacy `2025-11-25` dialect remain later tests of
execution and session boundaries.

The evidence architecture and official-runner boundary are documented in
[protocol-compliance.md](protocol-compliance.md).

The non-runtime Dialyxir and Credo gates described in
[static-analysis-plan.md](static-analysis-plan.md) are now active and clean:
strict Credo reports no issues under the documented policies, and Dialyzer
reports no warnings and uses no ignore file.
