# Changelog

All notable changes to `snodo` and its sibling packages are recorded here. The
format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Nothing
has been published yet.

## Unreleased

### Added

- Protocol core for MCP `2026-07-28`: discovery, tools, resources and templates,
  prompts, completion, pagination with cache hints, `subscriptions/listen`,
  progress, cancellation, and multi round-trip requests with form and URL
  elicitation.
- Opt-in initialize-era HTTP dialects for `2025-11-25` and `2025-06-18`.
- `use Snodo.Server` with `Snodo.Tool`, `Snodo.Resource`, and `Snodo.Prompt`,
  the concise `Simple` forms, and inline `tool`, `resource`, and `prompt`
  blocks.
- `Snodo.Client` with in-process, stdio, and Streamable HTTP transports.
- Stdio transport, a native Streamable HTTP listener, and
  `Snodo.Server.Executor` for bounded, cancellable execution.
- Application authorization across discovery and invocation.
- `Snodo.Subscription.Hub`, dependency-free instrumentation, and the extension
  registry.
- Sibling packages: `snodo_plug`, `snodo_jsv`, `snodo_tasks`,
  `snodo_tasks_postgres`, and `snodo_tasks_sqlite`.
- `x-mcp-header` tool arguments (SEP-2243). `Snodo.Tool` validates the
  annotation when a tool compiles. Both HTTP listeners check `Mcp-Param-*`
  headers against the body and refuse a missing or mismatched one with 400 and
  -32020. `Snodo.Client` sends the headers when `call_tool/4` gets the tool
  definition, retries a name-only call once after -32020, and over HTTP leaves
  tools with invalid annotations out of its lists.
- `Snodo.Client` sends `io.modelcontextprotocol/clientInfo` with every request:
  the new `:client_info` option, or `snodo` and the library version.
- `:allowed_hosts` on the native listener and `Snodo.Transport.Plug` requires
  the `Host` header to name a listed host.
- `:disconnect_probe_ms` on `Snodo.Transport.Plug` (default 5,000). A request
  still running after that long switches to SSE keepalives, so a client
  disconnect cancels the work.
- `:max_line_bytes` on the stdio transport and on `Snodo.Client` over stdio
  bounds one frame.

### Changed

- Renamed from `mcp_ex` and `MCP.*` to `snodo` and `Snodo.*`, because the
  package name and the module namespace collide with existing hex packages.
- Tool input validation failures, including missing required arguments, are
  `isError` tool results instead of -32602 JSON-RPC errors, as the 2026-07-28
  tools specification asks. Messages name the location and the rule, never the
  value.
- Initialize-era dialects answer JSON-RPC errors with HTTP 200.
- Initialize-era `tools/list` leaves out tools whose input or output schema is
  not an object instead of failing, and a call to one is refused with -32602.
  `Snodo.Server.Runtime.new/1` logs a warning naming them.
- A cancelled request on the native listener is answered with 204, as on the
  Plug adapter.
- An `Origin` allowlist entry with a port pins the port, and an `Origin` with
  userinfo is refused.

### Fixed

- Stdio no longer corrupts non-ASCII text on Latin-1 input devices or
  Unicode output devices.
- Response objects sent to a server, and notifications that fail to decode,
  get no reply.
- Stdio strips a leading UTF-8 byte order mark.
- A client disconnect cancels a handler that reports nothing on the Plug
  adapter.
