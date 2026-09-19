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
   - Initial reconciliation checkpoint: 228 core tests, 130 application tests,
     25 contract groups,
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
     Initial MRTR checkpoint: 272 core tests, 85 Tasks tests, 29 core contract groups,
     core static-analysis gates, and official-client automatic retries over
     stdio/HTTP; the existing target application still passes its 130 tests.
   - External fixture close-out is complete: the pinned alpha.11 run now passes
     32/37 required scenarios, including nine newly exercised ordinary MRTR
     scenarios. Official-client checks and a strict per-check external regression
     baseline are wired into CI; local passes do not imply CI has run.
   - Deprecated roots/sampling still need separate validation and client evidence
     before being advertised. Async Tasks continue using their own input lifecycle
     rather than an implicit MRTR bridge.
3. **Recommended application stack — implemented locally.**
   - Provide a tested Plug/Bandit integration with streaming, disconnect cleanup,
     origin/header admission, and application authentication context.
   - Select an optional complete JSON Schema backend and document recommended
     validation defaults. Keep `Basic` explicitly bounded.
   - Add request progress and ordinary response streaming for the promised
     workflows, with bounded execution and graceful shutdown evidence.
   - Implemented separate Plug/Bandit and JSV integration packages; examples
     21/22 demonstrate public application setup and compiled validation. Core
     remains dependency-free. Progress now works over stdio, native HTTP, and
     Plug with request-scoped sinks. See [recommended stack and limits](application-stack.md).
4. **Independent protocol regression evidence — implemented and exercised locally.**
   - Pin schema and runner provenance and validate representative emitted
     messages with a complete schema engine.
   - Translate tower-mcp failure cases into reusable protocol fixtures covering
     saturated cancellation, header mismatch, disconnects, notifications,
     retries, and terminal-state races.
   - Compare semantic outcomes across independent implementations and clients;
     resolve disagreements against the specification.
   - Keep failures, absent fixtures, deprecated features, and implementation
     gaps explicit. Historical conformance scores are dated observations.
   - Implemented pinned runner/provenance and regression CI with all 190 check
     occurrences pinned across required and unscored scenarios, plus a
     separate AJV corpus validating 78 actual emissions with 78 negative
     mutations. Real-client progress checks document an SDK callback scheduling
     race separately from the correct ordered wire behavior.
5. **Application workflows — implemented locally; release readiness remains gated.**
   - Package discovery with prompts, completion, pagination, and cache hints.
   - A durable package audit using Tasks, SQLite, and subscription updates.
   - An ordinary operation that requests input through MRTR and resumes.
   - Run examples through the public API and supported transports, document
     actual host capabilities, and define a versioned feature/support profile.
   - The real application now supplies package-name completion, eight-entry
     catalog pages with public cache hints, and a read-only `package_review`
     prompt with optional ordinary MRTR focus selection. Official-client 2.0.0
     exercises all three tool pages, two completion paths, and automatic review
     retry over both stdio and HTTP.
   - The opt-in target `AuditWorkflow` composes Tasks, SQLite, the real domain
     audit, and scoped snapshot subscriptions. Eleven focused tests cover
     restart/recovery, cancellation, tenant isolation, reaping, and authenticated
     Plug/Bandit HTTP/SSE. An offline executable demonstrates durable recovery
     and terminal-state reconnect. This is not a production security audit
     service: reports retain domain limitations, and deployment still needs
     authentication policy, quotas, retention and operational acceptance.
   - [Release gates and versioned support profile](release-readiness.md) define
     what remains. License/distribution is a user decision; local changes do not
     publish or deploy either repository.

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
