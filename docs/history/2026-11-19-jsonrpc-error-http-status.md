# JSON-RPC error HTTP status, 2026-11-19

Issue #425 asked whether the native listener and Plug should distinguish
request validation from method execution when assigning HTTP status to
JSON-RPC errors on 2026-07-28. A malformed request and a valid request for a
missing resource both produced HTTP 400 with JSON-RPC -32602. An internal
handler error produced HTTP 500 with JSON-RPC -32603.

This decision applies to 2026-07-28. Initialize-era HTTP statuses stay as
before. Those dialects already send dispatch errors on 200.
[Initialize-era clients](../../guides/initialize-era-clients.md).

## Specification and SDK behavior

The Streamable HTTP binding specifies JSON or SSE for a request response.
It requires HTTP 403 for an invalid Origin, 400 for header mismatches and
unsupported versions, and 404 for unimplemented methods. Accepted
notifications use 202 and rejected notifications use an HTTP error status.
The Backward Compatibility section also describes 400 for missing required
client capabilities.
It gives no general status rule for JSON-RPC request errors and assigns
neither -32602 nor -32603 an HTTP status. The resources page requires -32602
for a missing resource and recommends -32603 for internal resource errors.
[Streamable HTTP](https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/streamable-http),
[Error codes](https://modelcontextprotocol.io/specification/2026-07-28/basic#error-codes),
[Resources](https://modelcontextprotocol.io/specification/2026-07-28/server/resources#error-handling).

The TypeScript v2 HTTP server sends handler-produced -32602 and -32603 on
HTTP 200. It has an explicit post-dispatch exception for -32021 before the
response stream starts. Python v2 main uses one table for both classifier and
handler replies in JSON mode. It maps -32602 to 400 and leaves -32603 at its
default 200. Python issue #3855 discusses moving accepted-request failures
such as a missing resource onto HTTP 200. An unexpected 400 can cause a
dual-era client to attempt legacy initialization because -32602 is outside
the recognized modern rejection codes.
[TypeScript v2 server migration guide](https://ts.sdk.modelcontextprotocol.io/v2/migration/support-2026-07-28),
[Python HTTP writer](https://github.com/modelcontextprotocol/python-sdk/blob/main/src/mcp/server/_streamable_http_modern.py),
[Python status table](https://github.com/modelcontextprotocol/python-sdk/blob/main/src/mcp/shared/inbound.py),
[Python SDK #3855](https://github.com/modelcontextprotocol/python-sdk/issues/3855).

Both SDKs' high-level tool APIs use an `isError` result for ordinary
tool argument validation failures. The HTTP mapping above applies when
the server actually emits a JSON-RPC error, such as an invalid-params
error from a low-level handler.
[TypeScript error handling](https://github.com/modelcontextprotocol/typescript-sdk/blob/main/docs/servers/errors.md),
[Python error handling](https://github.com/modelcontextprotocol/python-sdk/blob/main/docs/servers/handling-errors.md).

## Conformance and interop

The pinned conformance runner, 0.2.0-alpha.12, checks the missing resource
response for -32602, the requested URI in the error data, and the absence of
an empty contents result. The native and Plug baseline records all three
checks as successful. Upstream PR #554 proposes grading the error code as a
requirement. Its change concerns the JSON-RPC error code. The modern baseline
also inventories explicit 400 and 404 checks for metadata, capability,
version, header, and unknown method failures. No baseline change is
expected from the execution status change. The upstream Tasks dispatch check
`sep-2663-tasks-get-invalid-task-id-32602` checks the JSON-RPC error code.
The native and Plug baseline records it as successful, and the proxy baseline
records a failure because that lane does not route Tasks.
[Resource scenario](https://github.com/modelcontextprotocol/conformance/blob/main/src/scenarios/server/resources.ts),
[Conformance PR #554](https://github.com/modelcontextprotocol/conformance/pull/554),
[Tasks dispatch scenario](https://github.com/modelcontextprotocol/conformance/blob/main/src/scenarios/server/tasks/dispatch.ts).

The official client scripts check decoded errors. The wire-schema lane also
checked the raw HTTP status and expected 400 for every JSON-RPC error in its
corpus. It now expects 200 for the tool's invalid-arguments error and the
missing skill, and 400 for the missing-capability errors.

## Decision

For -32602 and -32603, the status depends on whether request validation
passed. `validate_route/5` calls the dialect's or extension's
`validate_operation/3`. Use HTTP 200 after that validation passes. This
covers lookup, middleware, handler, and result failures. Keep the existing
statuses for transport admission and protocol validation, including 400 for malformed params and 404 for
unknown RPC methods. Preserve the existing mappings for reserved protocol
errors, including 400 for -32021 during result validation.

A non-string cursor gets 400 and a well-formed stale cursor gets 200.
A non-map `inputResponses` gets 400 and an invalid answer consumed from a
valid map gets 200. The Tasks error `Task input is larger than N bytes`
arises in `around_dispatch/4` and moves from 400 to 200. Non-object
`tools/call` arguments get 400. Tool schema and missing required argument
failures already return `isError` results on 200.

Executor timeouts, faults, capacity refusals, and duplicate in-flight IDs
keep their existing HTTP statuses.

Dispatch supplies the execution outcome alongside the existing JSON-RPC
reply to the shared HTTP implementation. Direct, stdio, and initialize-era
callers retain the existing dispatch interface. An already-open SSE stream
carries its terminal error in-band.

HTTP monitoring and callers checking only the HTTP status now see an
accepted exchange for these errors. The JSON-RPC error code, ID and data
remain available to distinguish a missing resource from a handler fault.
