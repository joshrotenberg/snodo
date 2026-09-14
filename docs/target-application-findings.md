# Target application findings

The `hexpm-mcp` checkout is the first application acceptance target for
`mcp_ex`. The port and its reconciliation are local, uncommitted work. This
document records the current code, the problems it exposed, and the evidence
still needed before calling the application ready. The broader sequence is in
[the application readiness plan](application-readiness-plan.md).

## Current state

The target registers 24 tools, five prompts, one concrete resource, and four
resource templates. Its server selects `MCP.Protocol.V2026_07_28` and explicitly
installs `MCP.Schema.Validator.Basic`. Domain operations remain behind the
existing `HexpmMcp` API; the reconciliation changes MCP adapters and validation.

All 24 tools now use `MCP.Tool.Simple`. Twenty-three declare their inputs with
`argument/3`; the zero-argument `toolbox_groups` tool retains an
`input_schema(%{"type" => "object"})` override. This preserves its original
definition exactly instead of adding an empty `properties` map. The full
pre-conversion catalog was captured from the source AST in
`hexpm-mcp/test/fixtures/mcp_tool_catalog.json`. All 24 names, descriptions,
input schemas, and required-argument ordering match that snapshot.

The target currently runs the framework's native
`MCP.Transport.StreamableHTTP.Server` for HTTP. Stdio runs one temporary,
supervised `StdioLifecycle` Task that calls public `MCP.Transport.Stdio.serve/2`.
It drains admitted requests before exiting 0 on EOF, and reports failures to
stderr before exiting 1. Owning the serving call removes the race between a
separate transport child and lifecycle monitor. Subprocess tests exercise the
actual application's empty EOF and discovery-before-EOF paths, plus transport
startup failures and serving exceptions. There is no Plug/Bandit integration yet.

The framework dependency defaults to the sibling `../mcp_ex` checkout, with
`MCP_EX_PATH` available to select another path. The target declares Elixir
`~> 1.18`. Dependency packaging, release builds, deployment, and compatibility
with additional client hosts remain acceptance work.

## Findings and reconciliation

### Elixir values need an explicit JSON conversion boundary

The domain layer returns atom-keyed maps and structs. Passing these directly
to `MCP.Resource.json/3` fails the framework's JSON-value validation.
`MCP.JSONValue.encodable!/1` provides a public, recursive conversion with
collision detection: `:name` and `"name"` cannot silently overwrite each other.

The four JSON resources now call that helper before building their content.
The README resource continues to return text. This is an application boundary,
not a reason for the domain layer to adopt protocol-specific representations.

### Required arguments and schema validation solve different problems

The router enforces the published `required` list before tool dispatch even
with the pass-through validator. Missing keys therefore become invalid-params
responses rather than callback pattern-match failures.

The target now installs `Basic` as well, so supported constraints such as
declared input types are checked before callbacks run. `Basic` is a bounded
subset that ignores unsupported keywords; this application does not establish
full JSON Schema validation. A complete optional backend remains in the plan.
The redundant target-local schema validator was removed in favor of this
framework API.

### Resource matching should hand variables to the callback once

All four target resource templates now use the generated simple matcher and
read the extracted variables directly from their request parameters. They no
longer implement a matcher and repeat the same URI parse inside `read/2`.
The redundant target-local `ResourceURI` helper was removed as well. Both
removed helper files were untracked port scaffolding, so Git does not retain
their previous contents; their behavior is now covered through framework APIs.

The matcher is a deliberately narrow subset, with literal schemes and whole
authority/path-segment variables. The reconciliation also hardens its exact
boundary: doubled or trailing slashes and explicit ports must not match,
percent-encoded variables are decoded once with valid UTF-8, and repeated
variables must bind consistently. Unsupported template shapes still require
an application matcher. Resource overlap and application access policy remain
application responsibilities.

Schemes match case-insensitively; authority and path literals remain exact.
Compilation rejects invalid literal URI forms rather than installing a matcher
that could never accept a concrete URI. Valid percent-encoded literals remain
supported.

### Tool failures must be visible as tool results

Upstream failures, missing packages, and rejected domain preconditions now
return `{:ok, MCP.Result.error(message)}`, producing `isError: true` in the
tool result. The conversion also fixes branches that previously reported a
domain failure as successful text. Successful searches or documentation
listings with no entries still return successful results.

Invalid request shape, unknown methods/tools, and schema failures remain
protocol errors. Keeping these outcomes distinct lets a client present a
recoverable application failure without treating the MCP exchange as broken.

### Convenience APIs fit, with a useful escape hatch

The Simple DSL represents this catalog using types, required flags, and
descriptions. No additional DSL options were needed. The zero-argument schema
override demonstrates why the raw declaration path still belongs in the API.

Callbacks retain protocol-native string keys. Wire descriptions are explicit
rather than inherited from module documentation. These are visible migration
choices that can be documented without adding implicit conversion behavior.

## What the application establishes

The server definition builds a runtime without a named MCP server process.
The application still supervises its cache and transports. Tool, resource, and
prompt adapters use public framework APIs; the port has also supplied concrete
reasons to improve framework validation, JSON conversion, and template matching.

Direct dispatch makes catalog and routing checks straightforward, but
`MCP.Test.dispatch/2` supplies protocol metadata when its `protocol:` option
is present. Those checks must be paired with literal transport requests and an
independent client that sends its own metadata.

The first selected independent acceptance client is the official TypeScript
client, pinned at `@modelcontextprotocol/client` **2.0.0**. The application
acceptance run passed over both stdio and native HTTP using `2026-07-28` and the
client's modern protocol mode. It does not establish support in every host.

## Verification — 2026-09-14

The local validation runtime is Elixir **1.20.4** / OTP **29.0.6**, with
`ERL_FLAGS='+S 4:4'`. These are current-checkout results, not release artifacts.

Framework gates:

- `mix test --warnings-as-errors`: **228 passing** (one doctest, 227 tests).
- `mix mcp.contract`: **79 passing tests**, 25 evidence groups.
- `mix format --check-formatted`, dev `mix compile --warnings-as-errors`,
  `mix credo --strict`, and dev `mix dialyzer --format short --list-unused-filters`:
  passed, with zero Dialyzer errors and no suppressions added.

Application gates:

- `mix test --warnings-as-errors`: **130 passing tests**.
- `MIX_ENV=test mix credo --strict`: passed, 58 source files, no issues.
- `MIX_ENV=test mix format --check-formatted` and dev
  `mix compile --warnings-as-errors`: passed.
- Dev `mix dialyzer`: passed, zero errors and zero skips, with no suppressions
  added. The stdio Task uses a named entrypoint with an explicit `no_return()`
  contract for its intentional CLI halt.

Dependency rebuilds emitted upstream warnings from Makeup, ExDoc, Req, and
Burrito; no application compile warnings remain. No dependencies were upgraded
in this reconciliation.

The new `interop/official_client/check_hexpm.mjs` exercises the real server
definition and component callbacks against seeded application cache entries.
All external service URLs are redirected to loopback, so this is deterministic
application/client acceptance, not a live Hex.pm/HexDocs service test. On each
transport it verifies the 24-tool catalog, two successful tool calls, missing
package and upstream error results, invalid arguments, all five prompt renders,
and all five resource reads. HTTP also checks the absence of a session ID and
clean HTTP fixture shutdown. The stdio client check exercises the public
server and serving API; its SDK can force subprocess cleanup. Clean application
CLI EOF is established by the separate subprocess tests, not by SDK close.
The existing official-client echo/cancellation baseline
passed separately, including a successful request after cancellation.

From the framework checkout, after building the target application in `test`
and installing the pinned npm dependencies in `interop/official_client`:

```sh
HEXPM_MCP_BUILD_PATH=../hexpm-mcp/_build/test node interop/official_client/check_hexpm.mjs
node interop/official_client/check.mjs
```

Earlier claims of 148/160 target tests, live Bandit verification, and specific
line-count or timing improvements are not evidence for this checkout. The
historical external conformance score was not rerun, nor were unchanged
extension suites or the live PostgreSQL adapter lane in this slice.

The target has not been committed, released, or deployed as part of this
reconciliation. The subsequent [ordinary MRTR/elicitation slice](mrtr-elicitation.md)
is now implemented and verified separately. The recommended Plug/Bandit stack,
complete schema validation, durable application workflows, and expanded
independent protocol regression coverage remain next milestones. Consult
[protocol compliance](protocol-compliance.md) for feature-specific evidence;
a passing application suite is not a whole-protocol compliance claim.
