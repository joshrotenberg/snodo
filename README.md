# mcp_ex architecture spike

Development follows the [application readiness plan](docs/application-readiness-plan.md),
with `hexpm-mcp` as the first real application and independent protocol/client
evidence as the acceptance boundary.

`mcp_ex` is a router-first Elixir spike for the final MCP `2026-07-28`
protocol. The protocol core is a standalone, runtime-dependency-free Mix
library. The released Tasks proof is an independently buildable
`:mcp_ex_tasks` child package with a one-way dependency on that core; its
PostgreSQL and SQLite implementations are optional sibling packages:

- a synchronous, immutable router that needs no process;
- an explicitly configured, out-of-tree-extensible protocol registry;
- direct `server/discover`, Tools, Resources, Prompts, and Completion dispatch;
- an optional transport-neutral executor with bounded concurrency, a bounded
  queue, deadlines, and request-scoped cancellation;
- newline-delimited stdio built on that executor with atomic response writes;
- stdio `notifications/cancelled` handling with no late response;
- a dependency-free, localhost-first Streamable HTTP adapter and listener using
  the same executor;
- protocol-owned `subscriptions/listen` lifecycle over multiplexed stdio and
  long-lived HTTP SSE, backed by an application-owned pull source with one
  event in flight per subscription, plus negotiated extension-owned filter and
  event shaping without adding extension methods to the core profile;
- an opt-in, application-supervised `MCP.Subscription.Hub` producer with
  filter-aware broadcast, bounded per-listener queues, explicit overflow
  policy, delivery statistics, and core notification helpers;
- dependency-free instrumentation sinks for dispatch, subscription
  delivery/overflow, and Tasks runner/store-transition lifecycles, with bounded
  metadata and fault isolation;
- deterministic Tasks CAS-contention and Runner-soak workloads with a
  versioned JSON report, exact lifecycle invariants, and descriptive timings;
- exact preservation of JSON Schema maps and request `_meta` vendor keys;
- shared stateless pagination for all four list operations, with opaque
  protocol/method/catalog-scoped cursors and stable cache hints;
- a pinned complete core-method catalog plus an exact implementation profile
  and pure pre-router inspector;
- profile-derived capability admission that prevents false advertisement;
- an exact-versioned extension registry with collision checks, application
  options, bilateral negotiation, core-operation middleware, and
  extension-owned validation, wire shaping, and HTTP policy;
- a released `io.modelcontextprotocol/tasks` extension with an application-owned
  store/runner, versioned JSON-safe events, revisioned compare-and-set
  transitions, scoped access, serializable work, renewable fenced claims,
  restart recovery, deterministic mid-task input replay, a local durable DETS
  adapter, persisted exact-delay retry/backoff, cancellation races, and exact
  task routing headers;
- an optional `:mcp_ex_tasks_postgres` store with an application-owned
  `Ecto.Repo`, explicit migrations, JSONB aggregates and ledgers,
  database-clock leases, and `FOR UPDATE SKIP LOCKED` recovery;
- an optional `:mcp_ex_tasks_sqlite` store with an application-owned
  file-backed Repo, explicit migration, versioned JSON aggregates and ledgers,
  database-clock leases, and `BEGIN IMMEDIATE` single-writer serialization;
- a runtime-configurable `MCP.Schema.Validator` boundary;
- declarative `use MCP.Server`, `use MCP.Tool`, `use MCP.Resource`, and
  `use MCP.Prompt` developer APIs, with definition-owned completion callbacks.

The core runtime uses Elixir's built-in `JSON` module, available from Elixir
1.18, and has no runtime dependencies. The Tasks package depends at runtime
only on `mcp_ex`. Both database siblings depend inward on Tasks plus Ecto SQL
and Jason; Postgrex and `ecto_sqlite3` are optional because the host application
supplies and supervises its Repo. All four packages keep Credo and Dialyxir
development/test-only. The framework preserves and advertises schemas.
A custom validator can enforce inputs and structured outputs through
`validate/2`. The dependency-free runtime default remains intentionally
pass-through, while the included `MCP.Schema.Validator.Basic` enforces the
common object, array, primitive, enum, const, and size/bounds subset. A complete
JSON Schema backend remains application-selectable.

## Quick start

```elixir
defmodule Echo do
  use MCP.Tool,
    name: "echo",
    description: "Echo text"

  input_schema %{
    "type" => "object",
    "properties" => %{"text" => %{"type" => "string"}},
    "required" => ["text"]
  }

  @impl true
  def call(%{"text" => text}, _context) do
    {:ok, MCP.Result.text(text)}
  end
end

defmodule EchoServer do
  use MCP.Server,
    name: "echo-server",
    version: "0.1.0",
    protocols: [MCP.Protocol.V2026_07_28]

  tool Echo
end
```

For common object-shaped inputs, the opt-in simple layer generates that same
ordinary `MCP.Tool` definition without changing handler arguments or dispatch:

```elixir
defmodule SimpleEcho do
  use MCP.Tool.Simple,
    name: "echo",
    description: "Echo text",
    additional_properties: false

  argument "text", :string, required: true, min_length: 1

  @impl true
  def call(%{"text" => text}, _context), do: {:ok, MCP.Result.text(text)}
end

defmodule ValidatedEchoServer do
  use MCP.Server,
    name: "validated-echo-server",
    version: "0.1.0",
    schema_validator: MCP.Schema.Validator.Basic

  tool SimpleEcho
end
```

`argument/3` also accepts nested array types and raw property-schema maps. The
raw `MCP.Tool` DSL remains the direct path for fully hand-authored root schemas.

No process is needed for direct dispatch:

```elixir
{:ok, response} =
  MCP.Test.dispatch(EchoServer.runtime(),
    protocol: "2026-07-28",
    method: "tools/call",
    params: %{"name" => "echo", "arguments" => %{"text" => "hello"}}
  )
```

Run the first standalone walkthrough, or check all nineteen no-external-service
examples in isolated Elixir VMs:

```sh
mix run examples/01_direct_tools.exs
mix examples
```

Example 10 is a separate live-PostgreSQL setup walkthrough:

```sh
cd extensions/tasks_postgres
MCP_TASKS_DATABASE_URL=ecto://postgres:postgres@127.0.0.1:55432/mcp_ex_tasks \
  mix example.postgres
```

Example 11 is the embedded SQLite counterpart and needs no external service:

```sh
cd extensions/tasks_sqlite
mix example.sqlite
```

Example 13 mirrors all five guided prompts in the planned `hexpm-mcp` rewrite:

```sh
mix run examples/13_prompts.exs
```

Example 14 completes prompt and resource-template arguments using local,
context-dependent candidate data:

```sh
mix run examples/14_completions.exs
```

Example 15 traverses Tools, Prompts, Resources, and Resource Templates through
the shared pagination policy:

```sh
mix run examples/15_pagination.exs
```

Example 16 implements an application-owned subscription source and walks the
acknowledgement, bounded event, and graceful completion lifecycle:

```sh
mix run examples/16_subscriptions.exs
```

Example 17 runs from the independent Tasks package and contributes authorized
`taskIds` plus complete `notifications/tasks` snapshots to that same lifecycle:

```sh
cd extensions/tasks
mix run ../../examples/17_tasks_subscriptions.exs
```

Example 18 replaces the handwritten example source with the reusable bounded
hub and publishes a mutable application-owned resource update:

```sh
mix run examples/18_subscription_hub.exs
```

Example 19 observes dispatch and subscription pressure through the optional
dependency-free instrumentation sink:

```sh
mix run examples/19_instrumentation.exs
```

Each input message must be a single JSON object on one line. A modern request
must include:

```json
{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"echo","arguments":{"text":"hello"},"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}
```

## Architecture

```text
raw JSON-RPC map
  -> protocol registry
  -> exact protocol-profile inspection
  -> selected dialect context/admission
  -> core operation or negotiated extension route
  -> immutable router or extension callback
  -> protocol-neutral result or opened subscription
  -> selected dialect wire/stream shaping
```

`MCP.Router.dispatch/4` and `MCP.Server.dispatch/3` are synchronous and execute
in their caller. Direct code invokes them as ordinary functions. Transports or
applications may wrap that core with `MCP.Server.Executor`, which owns only
bounded admission, queueing, deadlines, cancellation tokens, and supervised
worker tasks, including cleanup when a submitting owner dies. The stdio adapter
owns framing, connection-local request tracking, outcome-to-wire mapping, and
atomic writes while delegating generic execution policy to that reusable layer;
applications may also inject and own the executor process.

The `2026-07-28` profile contains all 22 directional core method rules from the
pinned release schema: sixteen are implemented, and the remainder are explicitly
unsupported, deprecated, or MRTR-embedded. A known core method such as
`subscriptions/listen` is routed by the protocol profile and never mistaken for
a vendor extension.
Tasks remains extension-only and is not folded into the core catalog.

Resources use the same process-free router and server DSL as Tools. Direct
resources and URI templates are listed separately; `resources/read` routes an
exact URI through a direct registration or the resource module's explicit
`matches?/1` callback. This keeps inverse URI-template matching and access
policy application-owned. Text, JSON text, and base64 blob contents are
validated before dialect shaping, and all modern results include required
cache hints. Their list operations use the same stateless cursor engine as
Tools and Prompts. An application subscription source may emit resource-list
changes and exact requested resource updates without moving resource state into
the router. See `examples/12_resources.exs` for target-shaped
`toolbox://groups` and `hex://{name}/info` resources.

Prompts are first-class immutable router components with deterministic
`prompts/list` discovery and `prompts/get` rendering. Definitions preserve
titles, icons, argument metadata, and vendor `_meta`; the router enforces MCP's
flat string argument map and required arguments before invoking the handler.
Prompt messages support text, image, audio, embedded-resource, and resource-link
content, while list results carry independent cache hints and the shared cursor
policy. An advertised subscription source may emit prompt-list changes through
the shared stream lifecycle. See `examples/13_prompts.exs` for the five
target-shaped `hexpm-mcp` workflows.

Completion is definition-owned rather than globally registered. Prompts and
resource templates opt in with explicit `completion_arguments` and implement
`complete/2`, which receives a normalized `MCP.Completion` plus `MCP.Context`.
The router resolves exact prompt names and URI-template strings, validates
string arguments and context, caps results at 100 values, and shapes optional
`total` and `hasMore` hints without list-cache or cursor semantics. Resource
templates continue to own matching and expansion; completion does not add a
partial RFC 6570 implementation. See `examples/14_completions.exs`.

List pagination is applied once after protocol-neutral router dispatch. Routers
still return complete catalogs in stable name/URI order; `MCP.Pagination` slices
those results using a runtime policy whose default page size is 100. Configure
it declaratively with `pagination: [page_size: 50]` or override it in
`Server.runtime/1`. Cursors are deterministic and scoped to the protocol
version, list method, page size, and exact ordered catalog. A catalog or policy
change therefore returns `-32602` with `Pagination cursor has expired`, while a
malformed or cross-method cursor returns `Invalid pagination cursor`. Every
page preserves the list's `ttlMs` and `cacheScope`; `nextCursor` is omitted on
the final page. See `examples/15_pagination.exs`.

Subscriptions are request-scoped streams rather than router state.
`MCP.Subscription.Source` opens an application handle, negotiates a subset of
the capability-supported filter, blocks in `next/2`, and closes that handle on
cancellation, disconnect, completion, or failure. The framework writes the
required acknowledgement before starting a dedicated pull worker, never pulls
a second event until the previous one has been written, stamps the originating
JSON-RPC ID on every message, filters unrequested core events, and emits a
correlated terminal response on graceful source completion. Stdio multiplexes
streams and uses `notifications/cancelled`; HTTP returns `text/event-stream`,
disables proxy buffering, sends keepalive comments, and treats socket closure
as abrupt cancellation. Advertised exact-version extensions may contribute
validated filter fields and shape only events selected by their own accepted
filter. Applications that do not need a custom source can supervise
`MCP.Subscription.Hub`, pass `MCP.Subscription.Hub.source(hub)` to the runtime,
and publish core or extension events through its bounded, filter-aware queues.
The hub never detects application changes or mutates the router. See
`examples/16_subscriptions.exs`, `examples/17_tasks_subscriptions.exs`, and
`examples/18_subscription_hub.exs`.

`MCP.Instrumentation` accepts an application sink on the immutable runtime,
subscription hub, and Tasks runner. It emits telemetry-shaped names with native
duration measurements and bounded lifecycle metadata, but takes no dependency
on a metrics library. Sink faults are isolated from protocol behavior. See
`examples/19_instrumentation.exs` and
[`docs/instrumentation.md`](docs/instrumentation.md).

Dialects are a runtime allowlist. Loading a module does not enable it, and the
tests supply a `2099-01-01` dialect without changing framework code.

Applications can install a complete JSON Schema 2020-12 backend per runtime:

```elixir
EchoServer.runtime(schema_validator: MyApp.JSONSchemaValidator)
```

The module implements `MCP.Schema.Validator` and receives the original instance
and untouched schema map.

Applications that only need the included common subset can configure it on the
server, as above, or per runtime:

```elixir
EchoServer.runtime(schema_validator: MCP.Schema.Validator.Basic)
```

The same immutable runtime can be served over native HTTP:

```elixir
{:ok, http} =
  MCP.Transport.StreamableHTTP.Server.start_link(
    runtime: EchoServer.runtime(),
    port: 0
  )

MCP.Transport.StreamableHTTP.Server.url(http)
```

Applications with Plug, Bandit, or Cowboy can instead translate requests into
`MCP.Transport.StreamableHTTP.Request` and call the pure adapter. The built-in
listener intentionally implements one request per connection and complete JSON
responses or one request-scoped subscription SSE stream.

Out-of-tree modules implement `MCP.Extension`, declare exact-versioned
`MCP.Extension.Method` values, and are installed with `extensions:` on the
server. Runtime construction rejects duplicate IDs, collisions with every core
method (including unsupported and MRTR-only rules), and cross-extension method
collisions. An installed route executes only when both peers advertise it and
its callback accepts negotiation. Advertised, exact-compatible extensions may
also wrap core dispatch and contribute transport policy through generic hooks;
installed-but-unadvertised extensions remain inert.

The independently compiled Tasks package uses those hooks to augment
`tools/call` while keeping `tasks/get`, `tasks/update`, and `tasks/cancel`
outside the core catalog. It also owns `taskIds` admission, store-backed
visibility checks, and `notifications/tasks` shaping over the generic
subscription lifecycle. Its source, application setup, and package-local
quality commands are documented in
[extensions/tasks/README.md](extensions/tasks/README.md).

The optional PostgreSQL implementation accepts an already-running Repo and
never starts it or runs migrations implicitly; its schema, locking model, and
live transaction gate are documented in
[extensions/tasks_postgres/README.md](extensions/tasks_postgres/README.md).

The SQLite sibling keeps the same ownership boundary but deliberately promises
durable single-host execution rather than a multi-node queue. Its file, WAL,
single-writer, and recovery model is documented in
[extensions/tasks_sqlite/README.md](extensions/tasks_sqlite/README.md).

See [docs/spike-findings.md](docs/spike-findings.md) for the acceptance evidence,
architecture answers, and deliberate deferrals. The public API is assessed
against a real ported application in
[docs/target-application-findings.md](docs/target-application-findings.md). The protocol evidence model is
in [docs/protocol-compliance.md](docs/protocol-compliance.md), and the static
analysis gates are in [docs/static-analysis-plan.md](docs/static-analysis-plan.md).
The BEAM/PostgreSQL matrix and schema upgrade chain are in
[docs/compatibility.md](docs/compatibility.md).
The runnable index is in [examples/README.md](examples/README.md), and the
ordered plan—including both Ecto-backed walkthroughs—is in
[docs/examples-roadmap.md](docs/examples-roadmap.md).

## Interactive operations (MRTR)

Ordinary tools, resources, and prompts can return `MCP.Result.input_required/1`
with requests built by `MCP.Elicitation.form/2` or `url/2`. The current request
ends; a client retry invokes the handler again with a fresh request context.
Consume named answers with `MCP.Elicitation.response/3` and use `MCP.MRTR.State`
for integrity-protected state bound to the principal and original operation.
No suspended process or shared continuation store is required.

[Example 20](examples/20_mrtr_elicitation.exs) exercises a multi-round, read-only
workflow through all three feature families. The
[MRTR guide](docs/mrtr-elicitation.md) covers partial answers, error handling,
capability checks, state security, Tasks boundaries, and the pinned client check:

```sh
mix run examples/20_mrtr_elicitation.exs --check
node interop/official_client/check_mrtr.mjs
```

This slice supports form/URL elicitation and state-only continuations;
deprecated roots and sampling input requests remain unsupported.

## Verification

```sh
mix quality
mix quality.types
mix mcp.contract
mix examples
```

`mix quality` runs formatting, warning-free compilation, strict Credo, the
core ExUnit suite, all nineteen no-external-service example checks, and
then delegates to Tasks, PostgreSQL, and SQLite package quality, including
their independent test suites. `mix quality.types` runs Dialyzer with
unmatched-return and error-handling warnings enabled for all four packages.
Dialyzer has no ignore file; Credo has only the documented naming and
alias-policy exceptions. The default examples gate requires a POSIX host with
`sh` and `mkfifo` for its real stdio subprocess half-close check; examples
07–09 and 17 are delegated to Tasks, example 11 is delegated to SQLite, and example 10
stays in the opt-in PostgreSQL lane.

`mix mcp.contract` runs 29 core evidence groups across literal direct/stdio
vectors, native HTTP admission/listener behavior, and generic extension
registration and negotiated dispatch, including Resources, Prompts, and
Completion, Pagination, and Subscription routing and wire shapes. The
independent Tasks package runs 10 local evidence groups with:

```sh
cd extensions/tasks
mix quality
mix quality.types
mix tasks.contract
mix examples
mix tasks.stress
```

The stress command is an opt-in correctness workload rather than part of the
fast default gate. It exercises many-writer CAS and repeated runner batches,
can emit a versioned JSON artifact, and treats timings as observations rather
than portable pass/fail thresholds. See
[docs/stress-testing.md](docs/stress-testing.md).

The PostgreSQL sibling owns one database-free adapter group and 7 live evidence
groups. Its 14-test live lane uses an ordinary pooled Repo rather than SQL
Sandbox:

```sh
cd extensions/tasks_postgres
mix quality
mix quality.types
mix tasks.postgres.contract
MCP_TASKS_DATABASE_URL=ecto://postgres:postgres@127.0.0.1:55432/mcp_ex_tasks \
  mix quality.postgres
```

The SQLite sibling owns 7 local evidence groups backed by real temporary files
and an ordinary pooled Repo. They need no service or SQL Sandbox:

```sh
cd extensions/tasks_sqlite
mix quality
mix quality.types
mix tasks.sqlite.contract
mix example.sqlite
```

The core contract prints separate internal, unsupported, unmeasured, and
official evidence buckets. The local acceptance suites also cover 100 requests
entering a barrier concurrently,
100 atomic stdio responses, cancellation, malformed input recovery, exact wire
shapes, schema and metadata preservation, an application-supplied dialect, and
stdout/stderr isolation in a real OS subprocess. A separate pinned interop
harness also passes with the released official TypeScript client 2.0.0 in modern
mode for discovery, `tools/list`, `tools/call`, cancellation, and a follow-up
call. The frozen official server suite has also been run against the native
Streamable HTTP fixture: 22/37 exercised whole scenarios pass, with all 37
attempted. The raw runner had 25/37 scenarios without a failure check; three
unexercised or false-positive results are excluded from the honest score.

The separate extension-only Tasks probe passes all 35 Tasks-specific alpha.11
assertions. Start its combined fixture from the child package so both
applications are on the code path:

```sh
cd extensions/tasks
MCP_PORT=3001 mix run ../../conformance/fixture_server.exs
```

Eight generic core wire-schema checks still reject the
extension-defined `CreateTaskResult`, so the probe remains explicitly non-zero
and is not presented as a whole-scenario conformance pass.

For automation, `mix mcp.contract --format json --output mcp-contract.json`
writes one machine-readable JSON document after verifying the pinned frozen
requirement artifact and exact tagged test-evidence coverage. The output file
is isolated from compiler and test progress.

To repeat the external client check after `mix compile`:

```sh
cd interop/official_client
npm ci --ignore-scripts
npm run check
```

The companion `interop/official_client/check_hexpm.mjs` checks the real
`hexpm-mcp` server's 24-tool catalog, tool outcomes, five prompts, and five
resource reads over stdio and HTTP with seeded domain data. See
[target application findings](docs/target-application-findings.md) for the
build instructions, fresh evidence, and limits of that acceptance check.

## Scope boundaries

This is a design spike, not a production MCP SDK. It intentionally defers a
bundled JSON Schema 2020-12 engine, deprecated roots/sampling MRTR inputs,
legacy sessions, authentication, and per-peer fairness. Resources
cover paginated list/read/template routing and subscription event shaping, but
not a general RFC 6570 inverse matcher or a bundled change detector. Prompts
cover paginated list/get routing, required flat-string arguments, all five
content block types, and subscription event shaping; applications still decide
when a catalog changed. Tasks now has versioned serializable work descriptors, an
application-owned `WorkExecutor`, generic claim/renew/release/recovery/reap
callbacks, deterministic accepted-input replay, creation-based TTL cleanup,
and both volatile memory and local durable DETS adapters. Exact-delay retry
policies are persisted with Work and enforced from store commit time. Recovery
is at-least-once: applications remain responsible for deduplicating external
effects with the stable work idempotency key. DETS remains a single-node
reference; SQLite supplies an application-owned embedded database with
single-writer transaction evidence, while PostgreSQL supplies multi-node
row-locking and database-clock claims. Neither adds Ecto to the protocol
packages. Their integration suites are meaningful evidence, not yet a
production-readiness or upgrade-matrix claim. The memory harness now provides a
repeatable contention and Runner-soak baseline, but it is not evidence of
database capacity, multi-node behavior, or operational endurance. Tasks status
notifications are implemented through the generic subscription lifecycle; the
application still owns publication from its store or domain process. The
adapters' choice to remove an entire aggregate at
`createdAt + ttlMs` is this
implementation's allowed expiration policy, not a universal protocol mandate.
The released-client check covers only the implemented stdio slice, while the
separate frozen official server run exercises the native HTTP fixture. Its
current honest score is partial: 22 of the 37 frozen `2026-07-28` server
scenarios pass as exercised whole scenarios. This is not a full-revision
conformance claim. Basic executor backpressure is implemented, but per-peer
fairness, adaptive load shedding, general non-subscription response
streaming, and graceful listener-wide subscription draining remain future
work. The stdio adapter's optional
default-Logger redirection changes VM-global Logger configuration and is
intended for the normal single-stdio-server process; restoration/lease
coordination for multiple embedded stdio adapters is not implemented.

The official run summary is available in
[human-readable](conformance/results/2026-07-28-alpha.11-summary.md) and
[machine-readable](conformance/results/2026-07-28-alpha.11-summary.json) forms.
The separate Tasks probe is also available in
[human-readable](conformance/results/2026-07-28-tasks-alpha.11-summary.md) and
[machine-readable](conformance/results/2026-07-28-tasks-alpha.11-summary.json)
forms.

The wire fixtures follow the official [MCP 2026-07-28
specification](https://modelcontextprotocol.io/specification/2026-07-28),
[discovery contract](https://modelcontextprotocol.io/specification/2026-07-28/server/discover),
[tools contract](https://modelcontextprotocol.io/specification/2026-07-28/server/tools),
[resources contract](https://modelcontextprotocol.io/specification/2026-07-28/server/resources),
[prompts contract](https://modelcontextprotocol.io/specification/2026-07-28/server/prompts),
and [stdio binding](https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/stdio).
