# Pinned official wire-schema validation

This development-only lane validates **actual serialized server emissions** with
AJV's full JSON Schema 2020-12 engine. It is independent of the official TypeScript
client checks and the external conformance runner. It adds no Elixir runtime
dependency and is not an application argument-validator backend.

From the repository root:

```sh
ERL_FLAGS='+S 4:4' mix compile --warnings-as-errors
cd interop/schema_validation
npm ci --ignore-scripts --no-audit --no-fund
npm run check
```

Node 22+ and the project's Elixir/OTP runtime are required. `SNODO_ELIXIR` may
select the Elixir executable; `SNODO_EBIN` may select another freshly compiled
core beam directory. `ERL_FLAGS` defaults to `+S 4:4` for the fixture children.
After dependency installation the check needs no Internet access: HTTP requests
stay on an ephemeral loopback listener. Each fixture is time-bounded and closed
after its lane. Failures produce a nonzero exit status.

## Evidence covered

The same public-API fixture runs in three fresh subprocesses: direct dispatch
through a JSON-lines adapter, real stdio transport, and the native Streamable HTTP
listener. No private test helpers or captured success responses are imported.

Each transport executes 20 operations and validates 26 emitted JSON messages:

- Discovery, tool listing, normal tool results, tool-domain errors, and typed
  JSON-RPC errors.
- Three acknowledged, token-correlated progress notifications before a normal
  tool result; these are request progress, not subscription events.
- Resource and resource-template lists, static and templated reads.
- Prompt listing/rendering and argument completion.
- Ordinary MRTR elicitation plus a fresh-ID retry for tools, resources, and
  prompts.
- A finite subscription: acknowledgement, tool-list event, resource-update event,
  and correlated terminal result. HTTP is parsed from its real SSE response body.

Across the three transports this is **60 operations / 78 emissions**, covering
26 explicitly selected response, result, and notification definitions plus their
referenced schemas. Every emission is also cloned and deliberately damaged to
prove rejection: 78 negative envelope controls. Seven separate unit tests exercise
deep content/schema failures, absent required cache/completion/subscription
structure, progress field types, definition lookup, and non-mutation. `npm test` runs only those unit
controls and does not start Elixir.

The final stdout line is a machine-readable JSON summary containing the schema
commit/digest and each transport's counts and named definitions. Assertions also
check fixture outcomes, retry correlation, subscription ordering, and cleanup;
those assertions are separate from upstream schema validation.

## Why named definitions and concrete result branches matter

The upstream schema root contains only `$schema` and `$defs`. Validating a message
against that root alone would be a no-op. `validator.mjs` selects the appropriate
named response/notification definition and rejects unknown mappings.

The pinned `InputRequiredResult` schema requires only `resultType`, typed as a
string; it does not encode all of that result's prose constraints. Consequently,
an ordinary `tools/call` result with malformed content can pass the response's
`anyOf` via that permissive MRTR branch. We additionally validate the **actual
concrete result branch** (`CallToolResult`, `ReadResourceResult`, `GetPromptResult`,
or `InputRequiredResult`). A unit control demonstrates the upstream union accepts
the damaged complete result and our concrete-branch validation rejects it.

The upstream artifact remains byte-for-byte unchanged. This lane does not claim
the schema encodes all protocol semantics or that all 155 definitions are covered.
Tasks, deprecated sampling/roots, URL-mode MRTR, cancellation failures, hostile
transport framing, every content variant, and every application schema are outside
this selected corpus. Other acceptance and protocol-contract tests cover separate
parts of that surface.

## Validation policy

AJV is exactly `8.20.0`, with all transitive versions and integrity values locked in
`package-lock.json`. We use its [2020-12 implementation](https://ajv.js.org/json-schema.html#draft-2020-12),
not its draft-07 default export.

- `format` is **annotation-only**, including URI, byte, and date-time formats.
  Formats are not silently presented as enforced assertions.
- No defaults, coercion, additional-property removal, or remote-reference loading.
  The official schema's own additional-property rules remain in effect.
- Normal schema assertions, composition, and local references are enforced.
  AJV's extra strict-authoring restrictions are disabled to consume the official
  generated artifact without changing it; validation itself remains enabled.
- Both vendored artifact digests are checked before any validator is compiled.
  Each successful validation verifies the message was not mutated.

## Provenance and license

`schema.json` is an unmodified copy of the official
[`schema/2026-07-28/schema.json`](https://raw.githubusercontent.com/modelcontextprotocol/modelcontextprotocol/5f5440bb26a62e2cf3440b92da5a667efa03b267/schema/2026-07-28/schema.json)
at commit `5f5440bb26a62e2cf3440b92da5a667efa03b267`.

Its SHA-256 is:

```text
ef70b61f99b6d2e5e3b46863822eab08dff6a45bedc7a08914e0e5b133f40203
```

It was retrieved from that immutable official URL and matched the local reference
checkout's schema bytes. That checkout's HEAD was a different commit; the lane's
source identity is the explicit immutable upstream pin, not the checkout's HEAD.

`SCHEMA_LICENSE` retains the complete
[upstream license file at the same commit](https://raw.githubusercontent.com/modelcontextprotocol/modelcontextprotocol/5f5440bb26a62e2cf3440b92da5a667efa03b267/LICENSE),
including its Apache-2.0/MIT licensing-transition notice and license texts.
Its SHA-256 is:

```text
0382b0057770ca05e9c350a50aa3b1c1fea84da0bc81d723bf00b9aa841be58a
```

`provenance.json` records both immutable source URLs and hashes. Updating the
schema requires reviewing the upstream change, retaining its applicable license,
updating the pin and digest together, and rerunning all positive and negative
controls. Checks never update or fetch the schema automatically.
