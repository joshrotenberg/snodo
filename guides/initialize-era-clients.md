# Initialize-era HTTP compatibility

The runtime remains 2026-only by default. Applications can opt into
`Snodo.Protocol.V2025_11_25` and `Snodo.Protocol.V2025_06_18` alongside
`Snodo.Protocol.V2026_07_28`, in that preference order after the latest dialect.
Merely loading a module does not enable it.

`initialize` selects the exact requested enabled legacy version, or the first
configured initialize-capable dialect for an unsupported proposal. Malformed
initialization and conflicting version headers fail. Subsequent requests use
`MCP-Protocol-Version`; missing headers are rejected because the March 2025
fallback dialect is not implemented. Initialization does not require that header.
`notifications/initialized` returns an empty HTTP 202 response. Ping is supported.
GET and DELETE return 405. JSON-RPC errors from executing a request, such as an
unknown tool or method, are returned with HTTP 200, because clients of these
revisions treat a non-2xx answer as a transport failure and 404 as an expired
session. Admission failures (media type, Origin, a missing or unsupported
`MCP-Protocol-Version`) keep their 4xx statuses. There is no HTTP session ID, session process, retained
client capability state, or lifecycle registry. Authentication remains application
owned and is evaluated for each request; session or client metadata never becomes
an identity. Applications must supply the existing cancellation scope for peers
that need separate request-id namespaces.

The shared router handles tools, prompts, resource lists/templates/reads,
completion and pagination. Legacy wire shaping omits 2026 resultType, cache and
server metadata fields. Legacy structured output and output schemas require an
object. Execution errors retain readable content with isError; protocol errors
remain JSON-RPC errors. Request-bound progress can use SSE; cancellation retains
the executor's authenticated isolation. Unsupported Tasks, continuation inputs,
subscriptions, server requests and legacy stdio are not advertised. No Tasks or
session-manager behavior is added.

Configured capabilities must be valid for every enabled profile. For a mixed
runtime, use the implemented base tools/prompts/resources/completions capabilities;
listChanged and subscribe remain unavailable on this legacy slice. Applications
that need latest-only subscriptions can expose a separate 2026-only runtime.

## Native client evidence

Isolated loopback checks on 2026-09-21 used actual Custode identity verification,
finite argument conversion and shared memory/operator callbacks, with scratch data.
Claude Code 2.1.273 `mcp list` initializes using 2025-11-25 and now connects and
lists tools. Codex 0.149.0 initializes using 2025-06-18, lists tools/resources and
templates, calls identity_echo and reads both a fixed resource and an instantiated memory
template URI without model inference.
Claude's restricted print session instead uses 2026 server/discover and successfully
calls the same identity tool. That two-turn check reports $0.01224, below its $0.50
cap, and exposes no built-in tools. Exact child process groups were bounded and
cleaned. These checks prove the implemented workflows, not general SDK conformance.

Private local traces remain outside the repository because they contain local
fixture details. Unit/integration tests in this PR exercise literal legacy
requests, shared routing, pagination, rejection cases, mixed-version routing,
HTTP progress, and cross-principal cancellation. Existing 2026 schema, client and
conformance lanes remain in place.

## Stack and distribution

This is stacked on private PR #1's exact head
`4a98d8393da586c039c173cfb80b07fcbc2ba961`. Keep the inherited SQLite Tasks failure
separate from compatibility results; no gate is removed or weakened.

Both Custode and snodo are private repositories. The owner explicitly confirmed
that snodo remains private during development.
Do not publish source or packages. This issue does not authorize a merge, a default
Custode dependency migration, or a live fleet cutover. A later local-only pilot can
use private path dependencies and narrow adapters around actual Custode callbacks,
shared operations and existing declared schemas: identity, journal_read,
remember/recall and one shared operator action. Replacing transport and removing
Anubis schema macros are separate changes.
