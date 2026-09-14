# Application readiness plan

## Goal

Build Elixir MCP applications that use the current `2026-07-28` protocol through
supported public APIs. Invest in `mcp_ex`, with a working `hexpm-mcp` application
and executable feature examples as the acceptance criteria.

The protocol core stays synchronous and independent of transports. Execution,
subscription producers, Tasks, database storage, and application conveniences
remain composable. A small core does not require applications to implement HTTP
servers or a complete JSON Schema validator themselves.

## Milestones

1. **Reconcile and verify the target application — complete locally, 2026-09-14.**
   - Correct JSON resource payloads and tool/domain error semantics.
   - Exercise `MCP.Tool.Simple` across the real tool catalog without changing
     published definitions.
   - Adopt template variable handoff and harden its exact matching boundary.
   - Establish fresh test, static-analysis, and transport interoperability
     evidence; replace unsupported claims in the findings document.
   - The user selected the official TypeScript client as the first acceptance
     target. Record its negotiated features and transport results. Additional
     hosts need their own evidence before claiming compatibility.
   - Evidence: 228 core tests, 130 application tests, 25 contract groups,
     formatting/Credo/compile/Dialyzer gates, and client 2.0.0 over stdio and
     HTTP. See [target application findings](target-application-findings.md)
     for reproducible commands and the distinction from deployment/conformance.
2. **General MRTR and elicitation — ordinary elicitation slice implemented.**
   - Give ordinary Tools, Resources, and Prompts a public input-required result
     and retry API, including request state, validated input responses, partial
     answers, repeated retries, cancellation, and extension composition.
   - Keep application effects explicit across retries. Tasks mid-flight input
     alone does not establish the general MRTR contract.
   - Add literal wire tests, official-client acceptance, and conformance
     fixtures alongside an application example.
   - Landed public result/context APIs, form/URL elicitation, request-bound signed
     state, partial/multiple-input retries, extension guards, and example 20.
     [MRTR evidence and limits](mrtr-elicitation.md) record the current slice.
     Local verification: 272 core tests, 85 Tasks tests, 29 core contract groups,
     core static-analysis gates, and official-client automatic retries over
     stdio/HTTP; the existing target application still passes its 130 tests.
   - Remaining: wire these cases into the pinned external conformance fixtures
     and rerun its lane; deprecated roots/sampling need separate validation and
     client evidence before being advertised. Async Tasks continue using their
     own input lifecycle rather than an implicit MRTR bridge.
3. **Recommended application stack.**
   - Provide a tested Plug/Bandit integration with streaming, disconnect cleanup,
     origin/header admission, and application authentication context.
   - Select an optional complete JSON Schema backend and document recommended
     validation defaults. Keep `Basic` explicitly bounded.
   - Add request progress and ordinary response streaming for the promised
     workflows, with bounded execution and graceful shutdown evidence.
4. **Independent protocol regression evidence.**
   - Pin schema and runner provenance and validate representative emitted
     messages with a complete schema engine.
   - Translate tower-mcp failure cases into reusable protocol fixtures covering
     saturated cancellation, header mismatch, disconnects, notifications,
     retries, and terminal-state races.
   - Compare semantic outcomes across independent implementations and clients;
     resolve disagreements against the specification.
   - Keep failures, absent fixtures, deprecated features, and implementation
     gaps explicit. Historical conformance scores are dated observations.
5. **Application workflows and release readiness.**
   - Package discovery with prompts, completion, pagination, and cache hints.
   - A durable package audit using Tasks, SQLite, and subscription updates.
   - An ordinary operation that requests input through MRTR and resumes.
   - Run examples through the public API and supported transports, document
     actual host capabilities, and define a versioned feature/support profile.

## Working rules

- Finish each milestone with reviewable code and repeatable evidence.
- Pull framework changes from application needs and protocol requirements.
- Do not expand DSL options or storage adapters until a workflow needs them.
- Preserve the distinction between extension support and core support.
- A green unit suite or an internal contract is not a whole-protocol or host
  compatibility claim.

## Acceptance target

An application author can build and run the promised workflows without using
private framework modules. Every advertised feature has tests at its semantic
boundary and independent wire/client evidence. Authentication, deployment,
validation, and host limitations have a documented application path.

## References

- [Current protocol](https://modelcontextprotocol.io/specification/2026-07-28)
- [Protocol evidence](protocol-compliance.md)
- [Target application findings](target-application-findings.md)
- [Examples roadmap](examples-roadmap.md)
