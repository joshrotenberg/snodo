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
object. A tool whose input or output schema is not an object is left out of
`tools/list` on these dialects, and a call to it returns -32602 before it runs;
`Snodo.Server.Runtime.new/1` logs a warning naming such tools when a legacy
dialect is enabled. The 2026-07-28 dialect still lists and calls them.
Execution errors retain readable content with isError; protocol errors
remain JSON-RPC errors. Request-bound progress can use SSE; cancellation retains
the executor's authenticated isolation. Unsupported Tasks, continuation inputs,
subscriptions, server requests and legacy stdio are not advertised. No Tasks or
session-manager behavior is added.

Configured capabilities must be valid for every enabled profile. For a mixed
runtime, use the implemented base tools/prompts/resources/completions capabilities;
listChanged and subscribe remain unavailable on this legacy slice. Applications
that need latest-only subscriptions can expose a separate 2026-only runtime.

## Official conformance

The official runner's frozen 2025-11-25 requirement set runs in CI against a
fixture with these dialects enabled: 21 of 30 required scenarios pass. The
2025-06-18 run has no frozen set; 21 of its 27 scenarios pass. The failures are
`logging/setLevel`, server-initiated sampling and elicitation, and
`resources/subscribe`, which this slice does not implement, plus a warning that
no session ID is issued. See the
[conformance lanes](https://github.com/joshrotenberg/snodo/blob/main/conformance/README.md#additional-server-lanes).

## Native client evidence

Loopback checks on 2026-09-21 against a real application server:

- Claude Code 2.1.273 `mcp list` initializes with 2025-11-25, connects, and
  lists tools.
- Codex 0.149.0 initializes with 2025-06-18, lists tools, resources, and
  resource templates, calls a tool, and reads both a fixed resource and a
  templated one.
- A restricted Claude print session uses 2026-07-28 `server/discover` and calls
  the same tool.

These checks show that the implemented workflows work with those clients. They
are not general SDK conformance. The test suite covers literal legacy requests,
shared routing, pagination, rejection cases, mixed-version routing, HTTP
progress, and cross-principal cancellation.
