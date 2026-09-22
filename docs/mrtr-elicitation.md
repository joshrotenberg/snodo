# Ordinary MRTR and elicitation

The first general MRTR slice supports ordinary tools, resources, and prompts
with form/URL elicitation and state-only continuations. It uses public APIs,
preserves the synchronous core, and needs no server-owned waiting process.
The implementation follows the pinned [2026-07-28 MRTR contract](https://modelcontextprotocol.io/specification/2026-07-28/basic/patterns/mrtr)
and [elicitation contract](https://modelcontextprotocol.io/specification/2026-07-28/client/elicitation).

## Authoring an interactive operation

1. Build a bare request with `MCP.Elicitation.form/2` or `url/2`.
2. Inspect `MCP.Elicitation.response(context, "choice", request)`.
3. On `:missing`, return `{:ok, MCP.Result.input_required(input_requests:
   %{"choice" => request})}`. That ends this request; it does not suspend it.
4. On retry, consume the named response, validate any state, then return the
   feature's normal result. Ignore inputs you do not need and re-request missing
   answers. Partial answers needed on a later retry belong in protected state.

The component's arguments do not gain hidden keys. Retry data is available as
`context.input_responses` and `context.request_state`. The raw originating
method and params are available as `request_method` and `request_params` for
binding verification. These are framework-owned fields; middleware should not
rewrite them when forwarding context to a handler.

Use [example 20](../examples/20_mrtr_elicitation.exs) and its
[shared workflow](../examples/support/mrtr_elicitation.exs) for a complete,
read-only preference flow that works as a tool, resource, and prompt:

```sh
mix run examples/20_mrtr_elicitation.exs --check
mix compile --warnings-as-errors
node interop/official_client/check_mrtr.mjs
```

The Node command needs the pinned dependencies installed with
`npm ci --ignore-scripts` in `interop/official_client`. It defaults to the dev
build; `MCP_EX_EBIN` selects a different compiled core. Its five automatic
workflows run over stdio and the native HTTP listener without public services,
opening a browser, or performing application mutations.

## State and effects

`MCP.MRTR.State.seal(data, context, secret: secret, principal: principal)` returns
an opaque signed token. Use the same options with `open/3` on retry. The helper
binds the method, salient parameters, explicit principal, and expiry, rejects
tampering, and bounds token size. JSON-RPC IDs and top-level retry/metadata fields
are excluded from the binding; nested argument fields are not. Map order does
not matter, but array order and numeric types do.

The application must provide a cryptographically random secret of at least
32 bytes and select the principal from trusted authentication context. Explicit
`principal: nil` means anonymous. The example uses a process-lifetime random
secret for anonymous loopback use; distributed deployments need shared secret
management. The default TTL is 300 seconds, capped at 900 seconds.

Tokens are readable, not encrypted. Do not put secrets in them. They can be
reused until expiry, so one-time operations need application-owned replay
tracking and idempotency. Authorization must still be checked on every request.
Do not perform a non-idempotent effect before returning input-required and assume
that the client will retry exactly once—or at all.

## Admission, errors, and composition

The dialect checks outgoing input-required placement and current peer
capabilities after middleware returns. Only `tools/call`, `resources/read`,
and `prompts/get` support this core result variant. The raw wire escape hatch
does not bypass these checks. Missing mode capability returns `-32021` with
`requiredCapabilities`; malformed retry envelopes return `-32602` before the
component runs. Unsupported result placement is a server error.

The new optional dialect `validate_result/3` hook does not change custom dialects
that omit it. Extension middleware runs anew on every retry and cannot enlarge
the original client's capabilities by passing an altered handler context.
Custom extension routes still own their semantics; embedded methods are not
top-level RPCs or new extension route registrations.

Typed callback failures (`{:error, %MCP.Error{}}`) now retain their documented
JSON-RPC error semantics for tools as well as resources/prompts. Previously the
tool router incorrectly converted them into `isError` results. Explicit
`MCP.Result.error/2` and legacy untyped tool failures remain tool error results.
This distinction matters for invalid elicitation answers and failed state
verification.

Input-required responses bypass final structured-output validation and resource
cache decoration. Final results still use the normal schema/content validation.
No executor slot is retained after the response. Elicitation `action: "cancel"`
is a returned user choice, separate from cancelling an active protocol request.

## Deliberate limits

- This slice supports elicitation and state-only continuation; deprecated roots
  and sampling input requests remain unsupported, as does extension-owned
  embedded request registration.
- Form schemas use the restricted flat primitive/enum subset, not arbitrary
  JSON Schema. Unsupported keywords are rejected. Formats have documented
  syntactic checks, not full RFC or service validation. The optional JSV backend
  now provides general tool schema validation; it does not widen this
  protocol-specific form subset. See the [application stack](application-stack.md).
- Form mode must not collect credentials. URL helpers accept HTTP(S) navigation
  only. URL acceptance indicates consent, not completion of an external action;
  applications must check that independently.
- Ordinary MRTR is not automatically converted into Tasks mid-flight input.
  Finish synchronous MRTR before creating a task, or use `Tasks.await_input/3`
  inside a task. A terminal task result cannot be another ordinary continuation.
- The pinned TypeScript client rejects empty `inputRequests` without a state
  string, despite the schema allowing an empty map. Core literal tests preserve
  the schema's shape; examples use nonempty input or state-only responses.
- Official-client acceptance is not a fresh external conformance-runner score,
  full wire-schema validation, or evidence for every MCP host.

## Initial MRTR checkpoint — 2026-09-14

Verified on Elixir 1.20.4 / OTP 29.0.6 with `ERL_FLAGS='+S 4:4'`:

- Core `mix test --warnings-as-errors`: **272 passing** (one doctest, 271 tests).
- `mix mcp.contract`: **107 passing tests**, **29 evidence groups**.
- Core formatting, strict Credo, dev warnings-as-errors compilation, and dev
  Dialyzer: passed; zero Dialyzer errors/skips and no new suppressions.
- Tasks `mix test --warnings-as-errors`: **85 passing**, including five new
  ordinary-MRTR/terminal-task boundary tests.
- Tasks `mix tasks.contract`: **71 passing tests**, **10 evidence groups**;
  test-environment formatting and strict Credo passed with no issues.
- Existing Hex.pm application suite: **130 passing**. Its separate pinned
  official-client acceptance also still passes over stdio and HTTP.
- Example 20 standalone `--check`: passed. It is registered in the default
  nineteen-example gate; the entire example set was not rerun in this slice.
- Official TypeScript client **2.0.0** MRTR check: both stdio and native HTTP
  passed, each with five automatic workflows, eight elicitation callbacks,
  and fifteen operation requests. Fresh IDs, state replacement/discarding,
  changed-argument rejection, and URL consent semantics are asserted.

The initial implementation did not rerun the external conformance runner,
unchanged storage-adapter suites, or Tasks/storage-adapter development Dialyzer.
The subsequent external fixture close-out passed **31/37** required scenarios,
including nine newly exercised ordinary MRTR scenarios. The later progress
slice raises the current score to **32/37**; the current aggregate evidence is
in [target application findings](target-application-findings.md#verification--2026-09-14).
See [conformance results](../conformance/results/2026-09-14-alpha.11-summary.md).
The official-client and frozen external regression checks are now wired into CI;
the checked-in workflow is policy until its remote job actually runs.

The literal acceptance suite covers all three feature families over direct,
stdio, and HTTP adapter boundaries; the independent client also uses a real
HTTP listener. Coverage includes multiple inputs, partial answers, repeated
rounds, extra IDs, declined/cancelled input, malformed responses, tampered state,
capability changes, final-output validation, and extension guards.
