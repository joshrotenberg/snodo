# Ordinary MRTR and elicitation

The first general MRTR slice supports ordinary tools, resources, and prompts
with form/URL elicitation, the deprecated sampling and roots input requests,
and state-only continuations. It uses public APIs, preserves the synchronous
core, and needs no server-owned waiting process. The implementation follows
the pinned [2026-07-28 MRTR contract](https://modelcontextprotocol.io/specification/2026-07-28/basic/patterns/mrtr)
and [elicitation contract](https://modelcontextprotocol.io/specification/2026-07-28/client/elicitation).

## Authoring an interactive operation

1. Build a bare request with `Snodo.Elicitation.form/2` or `url/2`.
2. Inspect `Snodo.Elicitation.response(context, "choice", request)`.
3. On `:missing`, return `{:ok, Snodo.Result.input_required(input_requests:
   %{"choice" => request})}`. That ends this request; it does not suspend it.
4. On retry, consume the named response, validate any state, then return the
   feature's normal result. Ignore inputs you do not need and re-request missing
   answers. Partial answers needed on a later retry belong in protected state.

The component's arguments do not gain hidden keys. Retry data is available as
`context.input_responses` and `context.request_state`. The raw originating
method and params are available as `request_method` and `request_params` for
binding verification. These are framework-owned fields; middleware should not
rewrite them when forwarding context to a handler.

Use [example 20](https://github.com/joshrotenberg/snodo/blob/main/examples/20_mrtr_elicitation.exs) and its
[shared workflow](https://github.com/joshrotenberg/snodo/blob/main/examples/support/mrtr_elicitation.exs) for a complete,
read-only preference flow that works as a tool, resource, and prompt:

```sh
mix run examples/20_mrtr_elicitation.exs --check
mix compile --warnings-as-errors
node interop/official_client/check_mrtr.mjs
```

The Node command needs the pinned dependencies installed with
`npm ci --ignore-scripts` in `interop/official_client`. It defaults to the dev
build; `SNODO_EBIN` selects a different compiled core. Its five automatic
workflows run over stdio and the native HTTP listener without public services,
opening a browser, or performing application mutations.

## Sampling and roots (deprecated)

SEP-2577 deprecates the server-initiated `sampling/createMessage` and
`roots/list` requests in 2026-07-28. Both are still defined by the protocol
schema and scored by the official conformance runner, so a handler may return
them as input requests next to elicitation. Prefer elicitation for new
designs.

1. Build a bare request with `Snodo.Sampling.create_message/2` (messages from
   `Snodo.Prompt.message/2`, a required `:max_tokens`, and optional model
   preferences, system prompt, stop sequences, temperature, `:include_context`,
   provider `:metadata`, `:tools`, and `:tool_choice`) or `Snodo.Roots.list/0`.
2. Inspect `Snodo.Sampling.response(context, "summary", request)` or
   `Snodo.Roots.response(context, "client_roots", request)`. A valid sampling
   response is a `CreateMessageResult` (role, content, model, optional
   `stopReason`); a valid roots response is a `ListRootsResult` whose root
   URIs start with `file://`. Malformed responses return `-32602`.
3. On `:missing`, return `Snodo.Result.input_required/1` as for elicitation.
   One result may mix all three kinds; the dialect checks every request
   against the client's capabilities and refuses the whole result with
   `-32021` when any is undeclared. Its `requiredCapabilities` is a
   `ClientCapabilities` object naming each unsupported request's need, such
   as `{"sampling": {"tools": {}}, "roots": {}}`. Sampling needs `sampling`,
   plus `sampling.tools` for `:tools` or `:tool_choice` and `sampling.context`
   for an `:include_context` other than `"none"`; roots needs `roots`.

Sampled content is model output the client chose to return: treat it as
untrusted input, bound what you keep in signed state, and never follow it as an
instruction. A root is a client claim about its file system, not an access
grant; check every derived path against the application's own authorization.
The conformance fixture in `conformance/support/mrtr.ex` shows a sampling
tool, a roots tool, a three-kind result with signed partial progress, and a
tool that requests only the kinds the client declared. On the client side,
`Snodo.Client` answers both kinds through its `:sampling` and `:roots` input
handlers and declares the matching capabilities only when a handler is
installed; see [the client guide](client.md#input-handlers).

## State and effects

`Snodo.MRTR.State.seal(data, context, secret: secret, principal: principal)` returns
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
that the client will retry exactly once, or at all.

## Admission, errors, and composition

The dialect checks outgoing input-required placement and current peer
capabilities after middleware returns. Only `tools/call`, `resources/read`,
and `prompts/get` support this core result variant. The raw wire escape hatch
does not bypass these checks. A missing elicitation mode, `sampling`, or
`roots` capability returns `-32021` with the merged `requiredCapabilities`;
malformed retry envelopes return `-32602` before the component runs.
Unsupported result placement is a server error.

The optional dialect `validate_result/3` hook does not change custom dialects
that omit it. Extension middleware runs anew on every retry and cannot enlarge
the original client's capabilities by passing an altered handler context.
Custom extension routes still own their semantics; embedded methods are not
top-level RPCs or new extension route registrations.

Typed callback failures (`{:error, %Snodo.Error{}}`) keep their documented
JSON-RPC error semantics for tools as well as resources and prompts. Explicit
`Snodo.Result.error/2` and untyped tool failures are tool error results
(`isError`).
This distinction matters for invalid elicitation answers and failed state
verification.

Input-required responses bypass final structured-output validation and resource
cache decoration. Final results still use the normal schema/content validation.
No executor slot is retained after the response. Elicitation `action: "cancel"`
is a returned user choice, separate from cancelling an active protocol request.

## Deliberate limits

- This slice supports elicitation, the deprecated sampling and roots input
  requests, and state-only continuation. Extension-owned embedded request
  registration remains unsupported. `Snodo.Client` answers all three kinds
  through its input handlers (see [the client guide](client.md)), and the
  pinned official client check exercises all three.
- Sampling requests are validated structurally (message roles, content block
  shapes, model preferences, tools, and tool choice), not semantically: the
  server does not check that a tool result answers an earlier tool use.
- Form schemas use the restricted flat primitive/enum subset, not arbitrary
  JSON Schema. Unsupported keywords are rejected. Formats have documented
  syntactic checks, not full RFC or service validation. The optional JSV backend
  provides general tool schema validation; it does not widen this
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

## Test coverage

The literal acceptance suite covers all three feature families over direct,
stdio, and HTTP adapter boundaries; the independent client also uses a real
HTTP listener. Coverage includes multiple inputs, partial answers, repeated
rounds, extra IDs, declined/cancelled input, malformed responses, tampered state,
capability changes, final-output validation, and extension guards. Sampling and
roots have their own literal round trips, malformed-response checks, and
`-32021` shapes for `sampling`, `sampling.tools`, `sampling.context`, `roots`,
and mixed results.
