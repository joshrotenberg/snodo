# Protocol compliance architecture

## Claim boundary

This project implements and tests a server-side slice of MCP `2026-07-28`.
It does not claim full revision conformance.

The profile, internal contract, released-client interoperability check, and
official conformance suite answer different questions and remain separate in
code and reports:

| Evidence lane | What it proves | Current status |
|---|---|---|
| Exact protocol profile | Which core methods exist in the pinned revision and which capabilities, methods, transports, and limitations this build implements | Complete catalog; implemented slice explicit |
| Core internal contract | Literal wire requests plus HTTP and generic extension acceptance obey the declared core slice | 25 evidence groups passing |
| Tasks package contract | The independent child package obeys its Tasks wire, lifecycle, subscriptions, HTTP, descriptor, durable-store, and recovery contract | 10 evidence groups passing |
| Released-client interop | A real official TypeScript client can discover, list, call, cancel, and call again over stdio | Passing with client 2.0.0 |
| Official server requirements | The implementation passes the frozen upstream scenarios for the released revision | Partial: 22/37 exercised whole scenarios pass; all 37 attempted |
| Full wire-schema validation | Every emitted message validates against the complete official schema | Not yet measured |

`mix mcp.contract` prints the core buckets without converting internal evidence
or unsupported features into an official score. The one-way-dependent Tasks
package owns its local evidence and runs it with `mix tasks.contract` from
`extensions/tasks`.

Each evidence group is attached to one or more ExUnit tests with a stable ID.
The core and Tasks contract tasks independently refuse to pass if their
executed modules do not cover their exact local inventories. For core
automation, `--output` writes only the rendered report to the named file; this
remains parseable even when a fresh Mix build emits compiler progress before
the task starts.

## Architecture adopted from tower-mcp

The useful idea in
[tower-mcp 0.22.1 at `10ada1d`](https://github.com/joshrotenberg/tower-mcp/commit/10ada1d01931fc94f78ae017923afb43a677da63)
is a two-stage admission boundary: validate JSON-RPC structure, then inspect one
exact MCP revision before semantic routing. Its protocol policy also keeps known
wire profiles, compiled implementations, and a runtime allowlist distinct.

The Elixir translation is:

```text
decoded JSON value
  -> MCP.Envelope                    JSON-RPC structure
  -> MCP.Protocol.Registry           explicitly enabled dialect
  -> MCP.Protocol.Inspector          exact profile and method contract
  -> dialect context/operation       lifecycle and metadata semantics
  -> Extension.Registry middleware     advertised exact-compatible augmentation
  -> MCP.Router / Extension.Registry   core or negotiated out-of-tree execution
  -> dialect wire shaping
```

`MCP.Protocol.Profile` is the exact-revision catalog and implementation manifest.
It records:

- the exact revision and lifecycle;
- batching and request-metadata policy;
- method kind, direction, top-level/MRTR placement, active/deprecated lifecycle,
  params policy, capability, validator, and implementation status;
- supported standard capability keys;
- transport evidence and explicit limitations.

The protocol registry rejects a dialect whose `version/0` or `era/0` drifts from
its profile. Runtime construction accepts only capability keys implemented by
every enabled profile plus the explicit open registries. An `extensions`
advertisement is valid only when each identifier has an installed extension;
discovery filters installed extensions to those compatible with the selected
exact protocol version. Nested standard settings are also tied to their
directional methods. The final profile implements the list-change and resource
subscription methods, while runtime construction additionally requires an
application `subscription_source` before any `listChanged: true` or
`resources.subscribe: true` advertisement is accepted. Discovery projects
capabilities through the selected profile. Completion is additionally derived
from registered opt-in prompt/resource-template callbacks, preventing an empty
router from advertising `completions`.

The pinned `2026-07-28` catalog contains 21 unique core method strings and 22
directional rules. The extra rule represents the two directions of
`notifications/cancelled`, whose server-side implementation status differs by
direction. Request-shaped `elicitation/create`, `roots/list`, and
`sampling/createMessage` are marked MRTR-embedded rather than top-level RPCs.
Tasks is extension-only and is absent from the core catalog.

A literal frozen table in the contract tests compares all 22 rules across name,
kind, direction, params presence, capability, implementation status, placement,
and lifecycle. It also asserts that the four Tasks extension methods are absent
from the core profile.

Inspection deliberately retains `implemented`, `unsupported`, and `extension`
classifications, but the server admission gate executes only `implemented`
methods. Thus `resources/list` and `completion/complete` are implemented core
methods, `subscriptions/listen` is implemented as a stream-opening request, and
`com.example/custom` is an extension candidate. A candidate executes only when
an exact-versioned route is installed, advertised by the server, advertised by
the client, and accepted by the extension's negotiation callback.

The subscription path is deliberately separate from router dispatch after the
request has opened. The application implements `MCP.Subscription.Source` and
owns any hub, database cursor, PubSub process, and backlog. The framework
narrows the requested core filter to advertised capabilities, rejects a source
that acknowledges anything outside that subset, and then pulls at most one
event at a time in a dedicated worker. Protocol shaping stamps the listen
request ID on the acknowledgement, every event, and the graceful terminal
response. Stdio owns multiplexing and response-free client cancellation; native
HTTP owns SSE headers, acknowledgement ordering, keepalives, socket disconnect
cleanup, and graceful source completion. Neither long-lived stream consumes a
slot in the generic request executor after `open/3` returns.

`MCP.Subscription.Hub` is an optional application-supervised implementation of
that same source contract. It accepts only events selected by each listener's
negotiated filter, bounds every listener queue, reports per-publication drops,
and offers explicit newest- or oldest-retention overflow policies. It remains
outside the runtime and router: applications decide when domain or registry
state changed and publish protocol-neutral core or extension events.

Instrumentation is evidence about implementation behavior, not an additional
protocol claim. The optional dependency-free sink observes dispatch outcomes,
subscription pressure, and extension-owned Tasks runner/store transitions
without changing wire messages, capability admission, routing, or the official
conformance score. Event metadata deliberately excludes request and task
payloads; the complete catalog is in
[`instrumentation.md`](instrumentation.md).

The extension registry is deliberately narrower than the protocol registry.
Extension-owned routes support top-level client-to-server requests only and
reject collisions against the complete core catalog, including unsupported and
MRTR-only names. An extension module owns semantic validation, dispatch,
success shaping, and error shaping; the server still enforces JSON-RPC
correlation and JSON-safe output. Separate optional callbacks can wrap core
dispatch or adapt the selected dialect's transport policy, but only for a
server-advertised, exact-compatible extension. Installed-only modules remain
inert, and callback faults become safe internal errors.

Tasks is the substantial proof of that split. Its independently compiled
`:mcp_ex_tasks` package depends one-way on `mcp_ex`, wraps `tools/call`, owns
`tasks/get`, `tasks/update`, and `tasks/cancel`, and requires `Mcp-Name` mirrored
from `params.taskId` without adding any Task-specific branch or dependency to
the core profile, router, or HTTP adapter. Direct, stdio, and HTTP acceptance
vectors therefore show that optional behavior can remain outside the dialect
module and core package.

The persistence proof stays behind that same extension boundary. A Task and its
versioned, JSON-safe `Work` descriptor are stored atomically before the creation
result is returned. The generic store contract supplies exact claiming,
claim-next recovery, renewal, release, worker-scoped reads, transitions, and
reaping. An application-owned `WorkExecutor` resolves descriptors on both
initial and recovered claims. A custom `work_builder` may project only the
stable tenant or principal identity needed for recovery; request contexts,
transport handles, and complete authentication structures are intentionally not
persisted.

Claims fence stale commits by generation, but recovery is at-least-once. The
application must use the descriptor's stable idempotency key for external side
effects. Accepted mid-task input is also durable: an identical recovered request
replays the persisted response without another input event, while changing the
request under an issued key is rejected. The DETS implementation proves reopen
and boot-epoch fencing on one node; it is deliberately not evidence for
distributed production claims. Both adapters choose to reap the entire
aggregate at the `createdAt + ttlMs` boundary and preserve `ttlMs: nil`
indefinitely. That is this project's permitted expiration policy, not a claim
that the protocol mandates eager physical deletion for every server.

This work reimplements the architecture in Elixir; no tower-mcp source was
copied. tower-mcp is licensed MIT OR Apache-2.0.

## Independent contract vectors

The tests under `test/compliance` use literal `_meta` keys and wire values. They
do not use `MCP.Test.dispatch(protocol: ...)`, because that helper obtains
metadata from the same dialect being tested and could allow request generation
and admission to drift together.

The current matrix covers:

- discovery, deterministic tool listing, text/structured/error tool results;
- exact profile method kind, direction, params, and metadata admission;
- standard and custom capability overclaim rejection plus separate known-core,
  unsupported, and extension method classification;
- unknown methods, malformed arguments, missing metadata, unsupported versions,
  header/body mismatch, and batch rejection;
- response-free cancellation notifications;
- direct/stdio wire equivalence and explicit null IDs for uncorrelatable stdio
  parse errors;
- deterministic static-resource and URI-template listing, explicit application
  matching, text/JSON/blob reads, cache hints, missing-resource errors, and
  direct/stdio wire equivalence;
- exact prompt and resource-template completion references, flat string context,
  definition-owned callback dispatch, bounded result validation, truthful
  capability admission, and direct/stdio/HTTP wire equivalence;
- Streamable HTTP origin, media type, mirrored-header, path, concurrency,
  cancellation, and application-owned-executor behavior;
- extension registration collisions, bilateral negotiation, context projection,
  validation/dispatch/result/error shaping, callback isolation, DSL integration,
  ordered core-operation middleware, application options, transport-policy
  composition, and direct/stdio parity; and
- in the Tasks package, flat creation/detail shapes, capability gating, sync
  fallback, tool vs protocol error semantics, partial mid-task input,
  deterministic accepted-input replay, scoped access, unknown IDs, immutable
  cancellation/completion races, idempotent terminal cancellation,
  task-specific HTTP headers, JSON-safe work/event/snapshot round trips, CAS
  conflicts, event-ID replay, action-scoped access, renewable generation-fenced
  claims, recovery after worker and store restarts, DETS corruption/version
  rejection, creation-based TTL reaping, and detached execution context.

Run it with:

```sh
mix mcp.contract
mix mcp.contract --format json
mix mcp.contract --format json --output mcp-contract.json
mix mcp.contract --format markdown
```

Run the independent Tasks evidence lane with:

```sh
cd extensions/tasks
mix tasks.contract
```

## Official conformance lane

The native Streamable HTTP fixture has been exercised by the frozen official
server runner. All 37 required scenarios were attempted. The honest score is
**22/37 exercised whole scenarios passed**. The raw runner had 25/37 scenarios
without a `FAILURE` check; three are excluded because missing fixtures or
warning-only paths did not exercise their intended behavior.

The required checks total 89 `SUCCESS`, 15 `FAILURE`, 5 `SKIPPED`, 2 `WARNING`,
and 1 `INFO`. Two pending, not-scored scenarios pass completely:
`json-schema-2020-12` (8/8) and `http-header-validation` (14/14). The remaining
custom-header pending failure stays visible in the checked-in report. The exact
pass list, raw no-failure list, and exclusion reasons are checked in as both
[JSON](../conformance/results/2026-07-28-alpha.11-summary.json) and
[Markdown](../conformance/results/2026-07-28-alpha.11-summary.md).

The frozen `2026-07-28` requirement manifest contains 37 scored server
scenarios. The manifest declares `conformance@0.2.0-alpha.10` as its historical
anchor, but was added retrospectively and first shipped with the alpha.11
runner. This project vendors the alpha.11 artifact from commit `c321dd3` and
verifies its exact SHA-256
`ae2f4f6210fd729e2e318edd5bbfa31a43cee0bc608e48052fa26dbf1d939b57`
before every core contract run. The combined frozen fixture includes Tasks, so
start it from the child package to put both applications on the code path, then
use the pinned runner with the frozen manifest:

```sh
cd extensions/tasks
MCP_PORT=3001 mix run ../../conformance/fixture_server.exs
```

```sh
npx -y @modelcontextprotocol/conformance@0.2.0-alpha.11 server \
  --url http://127.0.0.1:3001/mcp \
  --requirements 2026-07-28 \
  --output-dir conformance-results
```

`--requirements 2026-07-28` is preferable to a moving `--suite all` claim: it
fixes scenario membership and the wire revision. The upstream manifest is the
canonical definition of the score.

There is intentionally no expected-failures baseline in this project yet. The
measured failures remain visible. When a baseline is introduced, use narrow
`scenario:check-id` entries where possible and preserve both official rules:

- an unexpected failure breaks CI;
- a passing baselined check also breaks CI because the baseline is stale.

An expected failure remains a conformance failure; the baseline only stages CI
adoption.

## Tasks extension probe

The ten frozen alpha.11 Tasks scenarios are extension-only and do not contribute
to the 37-scenario core score above. They were run separately against the same
native HTTP fixture:

- all 35 Tasks-specific assertions passed;
- the one upstream status-notification assertion was skipped pending the
  runner's `subscriptions/listen` rewrite;
- one generic wire-schema check passed and eight failed; and
- the runner therefore exited non-zero.

Every generic failure rejects a flat Tasks `CreateTaskResult` as though it were
the core `CallToolResult` schema, which requires `content`. The extension
specification and the scenario-specific assertions require the flat
`resultType: "task"` shape instead. The checked-in summary keeps those failures
visible and claims only the 35 Tasks assertions:

- [human-readable Tasks summary](../conformance/results/2026-07-28-tasks-alpha.11-summary.md)
- [machine-readable Tasks summary](../conformance/results/2026-07-28-tasks-alpha.11-summary.json)

## Next compliance increments

1. Preserve the checked-in honest core summary while filling the 22 remaining
   required scenarios with real fixtures and framework surface; never promote a
   warning-only or missing-fixture result to a pass.
2. Add a narrow per-check expected-failures baseline only when CI adoption needs
   it, then fail both unexpected failures and stale passing baseline entries.
3. Pin the released official schema with provenance and validate representative
   messages using a complete JSON Schema 2020-12 engine; do not add a partial
   validator.
4. Keep the implemented retry policy and optional PostgreSQL and SQLite Tasks
   adapters in their own evidence lanes. Run and retain the checked-in
   PostgreSQL-version and migration-upgrade matrix, and add database-specific
   operational soak before making a production-readiness claim. The
   deterministic Memory contention/Runner harness is a common correctness
   baseline, not database capacity evidence.
   Retain the generic Tasks wire-schema failures until the official runner can
   validate extension result unions.
5. Add property/adversarial wire generation, a transport matrix, more official
   SDKs, and differential structural checks as separate lanes.

## Sources

- [tower-mcp protocol compliance](https://github.com/joshrotenberg/tower-mcp#protocol-compliance)
- [Official MCP conformance framework](https://github.com/modelcontextprotocol/conformance)
- [Frozen 2026-07-28 requirements at the alpha.11 commit](https://github.com/modelcontextprotocol/conformance/blob/c321dd32035556e6769d3724a8ee97d87c3faaac/requirements/2026-07-28.yaml)
- [Official SDK integration guide](https://github.com/modelcontextprotocol/conformance/blob/main/SDK_INTEGRATION.md)
- [MCP 2026-07-28 Resources](https://modelcontextprotocol.io/specification/2026-07-28/server/resources)
- [MCP 2026-07-28 Prompts](https://modelcontextprotocol.io/specification/2026-07-28/server/prompts)
- [MCP 2026-07-28 stdio binding](https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/stdio)
- [Pinned official 2026-07-28 schema](https://github.com/modelcontextprotocol/modelcontextprotocol/blob/5f5440bb26a62e2cf3440b92da5a667efa03b267/schema/2026-07-28/schema.json)
- [Released Tasks specification](https://github.com/modelcontextprotocol/ext-tasks/blob/0d0a6bd4c258b35caa3c810a1dd506cf105b1501/specification/2026-07-28/tasks.md)
- [Released Tasks schema](https://github.com/modelcontextprotocol/ext-tasks/blob/0d0a6bd4c258b35caa3c810a1dd506cf105b1501/schema/2026-07-28/schema.ts)
- [Frozen Tasks scenarios](https://github.com/modelcontextprotocol/conformance/tree/c321dd32035556e6769d3724a8ee97d87c3faaac/src/scenarios/server/tasks)
