# Target application findings

The `hexpm-mcp` checkout is the first application acceptance target for
`mcp_ex`. The port and its reconciliation are local, uncommitted work. This
document records the current code, the problems it exposed, and the evidence
still needed before calling the application ready. The broader sequence is in
[the application readiness plan](application-readiness-plan.md).

## Current state

The target registers 24 tools, six prompts, one concrete resource, and four
resource templates. Its server selects `MCP.Protocol.V2026_07_28` and explicitly
installs the optional `MCP.Schema.Validator.JSV` backend. Domain operations remain behind the
existing `HexpmMcp` API; the reconciliation changes MCP adapters and validation.

All 24 tools now use `MCP.Tool.Simple`. Twenty-three declare their inputs with
`argument/3`; the zero-argument `toolbox_groups` tool retains an
`input_schema(%{"type" => "object"})` override. This preserves its original
definition exactly instead of adding an empty `properties` map. The full
pre-conversion catalog was captured from the source AST in
`hexpm-mcp/test/fixtures/mcp_tool_catalog.json`. All 24 names, descriptions,
input schemas, and required-argument ordering match that snapshot.

The target currently runs the framework's native
`MCP.Transport.StreamableHTTP.Server` for HTTP. Stdio runs one temporary,
supervised `StdioLifecycle` Task that calls public `MCP.Transport.Stdio.serve/2`.
It drains admitted requests before exiting 0 on EOF, and reports failures to
stderr before exiting 1. Owning the serving call removes the race between a
separate transport child and lifecycle monitor. Subprocess tests exercise the
actual application's empty EOF and discovery-before-EOF paths, plus transport
startup failures and serving exceptions. An optional framework Plug/Bandit package
now exists, but the target's default HTTP startup has not switched to it.

The framework dependency defaults to the sibling `../mcp_ex` checkout, with
`MCP_EX_PATH` available to select another path. The target declares Elixir
`~> 1.18`. Dependency packaging, release builds, deployment, and compatibility
with additional client hosts remain acceptance work.

## Current discovery and interactive workflow slice

The September 14 follow-on adds bounded package-name completion to
`analyze_package`, `package_review`, and `hex://{name}/info`. It reuses the real
cached Hex API client, fetches at most one search page, filters literal prefixes,
and never invents a global completion total. Empty/short or non-name prefixes
do not trigger a network search. Upstream failures remain explicit errors.

The unchanged 24-tool catalog is now served in three eight-entry pages with
public 60-second cache hints. Prompts and resources carry the same catalog policy;
this does not cache per-user results or imply that all package data stays fresh
for that duration. The official client auto-aggregates pages; the acceptance
check also observes all three actual wire pages and the final absent cursor.

`package_review` asks for a missing quality/security/upgrade focus through
ordinary form elicitation. A fresh retry validates that input and returns a
read-only investigation plan. Decline/cancel produce a stopped outcome. Hosts
without elicitation can provide `focus` explicitly. No continuation token is
needed for this single-round, effect-free operation; a form answer is never
treated as identity or authorization. Existing 24 tool definitions are unchanged.

Local evidence: 137 application tests pass before durable-audit additions.
Official client 2.0.0 passes over both stdio and HTTP: three catalog pages,
six ordinary prompt renders, two package-completion paths, one automatically
resumed MRTR review, and the existing tool/resource acceptance checks. All domain
responses are seeded; no live package security assessment or deployment is claimed.

## Optional durable audit

`HexpmMcp.AuditWorkflow` builds on the same server catalog and JSV backend,
adding one required-task audit tool only to its opt-in runtime. The application
owns Repo startup, migrations, Runner, trusted tenant identity, and transport.
The default 24-tool startup never opens or migrates a database.

The workflow invokes the real `HexpmMcp.audit_dependencies/2` path and persists a
JSON report, exact package/version descriptor, idempotency key, collection window,
and explicit limitations. A completed task means a report was produced, not a
safe-package verdict. Restart recovery is at-least-once, and upstream data can
change between attempts. It is not a full lockfile/resolved-version vulnerability
assessment or an atomic archive of raw source responses.

Eleven focused tests verify real local Hex/OSV fixtures, file-backed SQLite
Repo/Runner restart, persisted results, authorization isolation, cancellation,
startup/periodic expiry cleanup, and status reconnect. Real authenticated
Plug/Bandit HTTP verifies trusted auth handoff, scoped reads, SSE ordering and
disconnect cleanup. An ordinary subscription disconnect does not cancel a
durable task; explicit authorized Task cancellation does.

The source emits authorized current snapshots; intermediate revisions can
coalesce and reconnect does not replay history. Task TTL is cleanup-driven, not
an exact-deadline authorization fence. The one-hour task/report retention is not
a permanent audit archive. Deployment requires tenant/task quotas and global
worker admission bounds; the current 32-ID source limit is not a pre-authorization
request limit. Plug/Bandit is currently a development/test target dependency,
not the default production host or authentication policy.

From the target checkout, see `docs/durable-audit.md` and run:

```sh
ERL_FLAGS='+S 4:4' mix run --no-start examples/durable_package_audit.exs --check
```

The offline example redirects service URLs to loopback and uses a fictional
cached zero-dependency release. It proves process/Repo restart recovery, not a
full VM power-loss test or a live package security conclusion.

## Findings and reconciliation

### Elixir values need an explicit JSON conversion boundary

The domain layer returns atom-keyed maps and structs. Passing these directly
to `MCP.Resource.json/3` fails the framework's JSON-value validation.
`MCP.JSONValue.encodable!/1` provides a public, recursive conversion with
collision detection: `:name` and `"name"` cannot silently overwrite each other.

The four JSON resources now call that helper before building their content.
The README resource continues to return text. This is an application boundary,
not a reason for the domain layer to adopt protocol-specific representations.

### Required arguments and schema validation solve different problems

The router enforces the published `required` list before tool dispatch even
with the pass-through validator. Missing keys therefore become invalid-params
responses rather than callback pattern-match failures.

The reconciliation first installed `Basic` so declared input types were checked
before callbacks ran. The application now selects the optional JSV backend for
Draft 2020-12 vocabulary, with non-mutating validation and its documented offline
schema-admission policy. The core `Basic` validator remains a deliberately
partial alternative. This backend selection is not universal wire conformance.
The redundant target-local schema validator was removed in favor of this
framework API.

### Resource matching should hand variables to the callback once

All four target resource templates now use the generated simple matcher and
read the extracted variables directly from their request parameters. They no
longer implement a matcher and repeat the same URI parse inside `read/2`.
The redundant target-local `ResourceURI` helper was removed as well. Both
removed helper files were untracked port scaffolding, so Git does not retain
their previous contents; their behavior is now covered through framework APIs.

The matcher is a deliberately narrow subset, with literal schemes and whole
authority/path-segment variables. The reconciliation also hardens its exact
boundary: doubled or trailing slashes and explicit ports must not match,
percent-encoded variables are decoded once with valid UTF-8, and repeated
variables must bind consistently. Unsupported template shapes still require
an application matcher. Resource overlap and application access policy remain
application responsibilities.

Schemes match case-insensitively; authority and path literals remain exact.
Compilation rejects invalid literal URI forms rather than installing a matcher
that could never accept a concrete URI. Valid percent-encoded literals remain
supported.

### Tool failures must be visible as tool results

Upstream failures, missing packages, and rejected domain preconditions now
return `{:ok, MCP.Result.error(message)}`, producing `isError: true` in the
tool result. The conversion also fixes branches that previously reported a
domain failure as successful text. Successful searches or documentation
listings with no entries still return successful results.

Invalid request shape, unknown methods/tools, and schema failures remain
protocol errors. Keeping these outcomes distinct lets a client present a
recoverable application failure without treating the MCP exchange as broken.

### Convenience APIs fit, with a useful escape hatch

The Simple DSL represents this catalog using types, required flags, and
descriptions. No additional DSL options were needed. The zero-argument schema
override demonstrates why the raw declaration path still belongs in the API.

Callbacks retain protocol-native string keys. Wire descriptions are explicit
rather than inherited from module documentation. These are visible migration
choices that can be documented without adding implicit conversion behavior.

## What the application establishes

The server definition builds a runtime without a named MCP server process.
The application still supervises its cache and transports. Tool, resource, and
prompt adapters use public framework APIs; the port has also supplied concrete
reasons to improve framework validation, JSON conversion, and template matching.

Direct dispatch makes catalog and routing checks straightforward, but
`MCP.Test.dispatch/2` supplies protocol metadata when its `protocol:` option
is present. Those checks must be paired with literal transport requests and an
independent client that sends its own metadata.

The first selected independent acceptance client is the official TypeScript
client, pinned at `@modelcontextprotocol/client` **2.0.0**. The application
acceptance run passed over both stdio and native HTTP using `2026-07-28` and the
client's modern protocol mode. It does not establish support in every host.

## Verification — 2026-09-14

The final local application validation runtime is Elixir **1.20.4** / OTP
**29.0.6**, with `ERL_FLAGS='+S 4:4'`, and Node.js **26.8.2**. These are
current-checkout results, not published artifacts or remote CI runs. Earlier
reconciliation checkpoints had smaller suites; they are not the current totals.

Application gates:

- `mix test --warnings-as-errors`: **148 passing tests**, including the eleven
  durable-audit tests.
- `mix format --check-formatted`, dev `mix compile --warnings-as-errors`,
  and `mix credo --strict`: passed; Credo checked 68 source files with no issues.
- Dev `mix dialyzer --format short --list-unused-filters`: passed with zero
  errors, zero skips, and no new suppressions.
- `mix run --no-start examples/durable_package_audit.exs --check`: passed,
  exercising offline SQLite recovery and working/completed/reconnect behavior.

Cold dependency builds emitted upstream Elixir 1.20 warnings about deprecated
`xref: [exclude: ...]` configuration and Burrito 1.5.0's struct update. The
application's own warnings-as-errors compilation passes. A narrow dependency
update fixed the observed Mint advisory and updated the test HTTP-server chain;
three Cowlib advisories remain unsuppressed in the test-only graph. See the
target checkout's `docs/dependency-audit.md` for versions and reproduction.

Framework and interoperability evidence:

- Core tests: **329 passing** (one doctest, 328 tests), **31 core contract
  groups**; Tasks: **85 passing**, **10 extension contract groups**.
- SQLite: **19 passing**, seven contract groups. PostgreSQL's default lane:
  **nine passing**, with **14 live-database tests excluded**; this run is not
  evidence for a running PostgreSQL server or its version matrix.
- Optional Plug/Bandit: **17 passing** real-server tests. JSV: **29 passing**
  adapter/router tests. The default example gate passes **21 examples**;
  external PostgreSQL example 10 remains opt-in.
- Independent AJV validation passes **78 emitted messages** from 60 operations,
  with 78 negative mutations, 26 concrete definitions, and seven harness tests.
- The frozen alpha.11 runner passes **32/37** required scenarios. Its raw exit
  remains 1 for the recorded failures; a passing regression baseline does not
  make them conformant. All 190 check occurrences are pinned, including the
  unscored lanes; twelve harness tests exercise regression accounting. See
  [protocol evidence](protocol-compliance.md).
- The official-client baseline, ordinary MRTR, progress, and application
  acceptance pass over both stdio and native HTTP. The pinned client has a
  separately documented unpaced stdio progress-callback scheduling race;
  ordered wire emission is not a promise that every client callback is delivered.

The final `interop/official_client/check_hexpm.mjs` run exercises the real
server definition and callbacks against seeded application cache entries. On
each transport it verifies the unchanged 24-tool catalog, three wire pages,
two successful tool calls, expected missing-package/upstream failures, invalid
arguments, six ordinary prompt renders, two completion paths, one automatically
resumed MRTR review, and five resource reads. All service URLs point to loopback:
this is deterministic application/client acceptance, not a live security audit.

HTTP checks the absence of a session ID and clean fixture shutdown. The SDK can
force stdio subprocess cleanup; the application's separate subprocess tests
establish clean CLI EOF, not the client's close method.

From the framework checkout, after building the target in dev and installing
the pinned npm dependencies:

```sh
ERL_FLAGS='+S 4:4' node interop/official_client/check_hexpm.mjs
ERL_FLAGS='+S 4:4' npm --prefix interop/official_client run check
ERL_FLAGS='+S 4:4' npm --prefix interop/schema_validation run check
ERL_FLAGS='+S 4:4' npm --prefix conformance run check
```

The framework's `mix quality` and `mix quality.types` aggregates pass across
all six packages, with zero Dialyzer errors, skips, or unnecessary filters. The
isolated example runner preserves the active Mix environment/build path; a
native HTTP cancellation regression now verifies sink closure before worker
cancellation and passed 501 repetitions. The release gate still requires the
private remote's BEAM and live
PostgreSQL matrix. A current-runtime local run is not evidence for those other
versions. No target commit, release, deployment, public endpoint change, or
package upload is claimed. Plug/Bandit, JSV, and durable application workflows
are implemented locally; licensing, distributable packaging, clean-consumer
acceptance, and production operations remain [release gates](release-readiness.md).

### Build-artifact hygiene

Final inspection found numbered duplicate BEAM files in generated build
directories, including copies whose bytes differed from their canonical
counterparts. Dialyzer was including those files, making earlier type results
unreliable. Only the numbered copies were moved aside: 166 framework artifacts
and 81 target artifacts. Canonical module files and source files were preserved.
The aggregate framework gates and canonical-only target type analysis were
rerun successfully after cleanup. Apparent Toolbox non-returning-function
diagnostics disappeared without source/specification changes or suppressions.

The origin of the duplicate files was not established. Recoverable copies from
this local run are under `/private/tmp/mcp-ex-duplicate-beams.kmCDpE`,
`/private/tmp/hexpm-mcp-duplicate-beams.Eklx50`, and
`/private/tmp/hexpm-mcp-duplicate-beams.A4v2Q9`. These are temporary build artifacts,
not source backups or release inputs. A clean consumer build remains a separate
distribution gate.
