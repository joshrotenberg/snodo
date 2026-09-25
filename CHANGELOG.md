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

### Changed

- Renamed from `mcp_ex` and `MCP.*` to `snodo` and `Snodo.*`, because the
  package name and the module namespace collide with existing hex packages.

### Fixed

- Stdio no longer corrupts non-ASCII text on Latin-1 input devices or
  Unicode output devices.
