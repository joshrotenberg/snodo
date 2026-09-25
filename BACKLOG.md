# mcp_ex backlog

Distilled from `WHERE-TO-NEXT.md` (agent_engine assessment, 2026-09-18) plus
its codex validation addendum. Items are sized S/M/L and ordered for solo
sessions; 1 and 2 are independent of each other (codex correction: the Plug
adapter does not need the client). Each item is scoped to be a single
branch/PR.

## Status, 2026-09-25

| Item | Status |
|---|---|
| 1. `MCP.Client.direct/1` | In progress in #8, as `MCP.Client.direct/2`. |
| 2. `:mcp_ex_plug` | Done in #1. |
| 3. `MCP.Client` transports | Open. Depends on 1. |
| 4. Ergonomics layer | Open. |
| 5. JSON Schema 2020-12 backend | Done in #1. |
| 6. Conformance + interop in CI | Done in #1. |
| 7. README protocol stance | Superseded by 8. The README documents the opt-in initialize-era HTTP dialects. |
| 8. Legacy session-era dialect | Done in #4 as opt-in `2025-11-25` and `2025-06-18` HTTP dialects. The trigger was #3: Claude Code 2.1.273 and Codex 0.149.0 could not initialize against the 2026-only server. It ships in the core rather than a sibling package, is stateless (no session IDs), and does not cover Tasks, subscriptions, server requests, continuation inputs, or stdio. |

Work that landed outside this list:

- #6 added application authorization across discovery and dispatch, for the
  Custode migration.
- #7 restored green CI after #6 merged without its final type-analysis fix.

Current baseline on `main`: 357 tests (one doctest, 356 tests), 31 internal
contract evidence groups, and 32/37 official conformance scenarios.

## Status, 2026-09-19

Work that had accumulated uncommitted in the working tree was landed on
`feat/application-stack`. It already contained three of the items below.

| Item | Status |
|---|---|
| 2. `:mcp_ex_plug` | **Done.** `integrations/plug`, 17 tests, example 21. |
| 5. JSON Schema 2020-12 backend | **Done.** `integrations/schema_jsv` wrapping `jsv`, 29 tests, example 22. |
| 6. Conformance + interop in CI | **Done.** `conformance/run.mjs` with a regression gate against `expected-failures.json`, plus `.github/workflows/protocol.yml`. The rerun the item asked for also happened. |
| 1, 3, 4, 7, 8 | Open, unchanged. |

The rerun answers item 6's second half: **32/37**, not the 22/37 these
documents carry. The five that remain are four `server-stateless` SEP-2575
checks plus `input-required-result-basic-sampling`, `-basic-list-roots`,
`-multiple-input-requests`, and `-capability-check`. Sampling and roots are
protocol-deprecated, so part of that gap is deliberate.

Item 1's acceptance numbers below are stale as written. The current baseline is
**329 tests** (one doctest, 328 tests) and **31 evidence groups**, not 272 and
29. The intent holds unchanged: if the evidence-group count moves, a compliance
test adopted the client and the change is wrong.

## 1. `MCP.Client.direct/1` — S, one sitting

The library has a server and no client; every example and the README reach
for the test-only `MCP.Test` and hand-parse wire maps. Scope EXACTLY per
WHERE-TO-NEXT "First PR": `lib/mcp/client.ex` with `direct/1`, `discover/1`,
`list_tools/1`, `list_resources/1`, `list_resource_templates/1`,
`list_prompts/1`, `call_tool/3`, `read_resource/2`, `get_prompt/3` —
envelope built the way `MCP.Test.put_protocol_metadata/4` does, dispatched
via `MCP.Server.dispatch/3`, decoded to structs / `%MCP.Error{}`. No stdio,
no HTTP yet. Underspecified areas to decide while building (codex): request
ID advancement through result-only returns, pagination, tool-error decoding.

Acceptance: tests > 272 and green with warnings-as-errors; `mix mcp.contract`
still reports 29 evidence groups (if that moves, revert — compliance tests
must not adopt the client); `mix examples` exact success strings unchanged;
`node interop/official_client/check.mjs` passes; README quick start no
longer contains the string `MCP.Test`; `lib/mcp/test.ex` untouched.

## 2. `:mcp_ex_plug` sibling package — M

Readiness-plan milestone 3 and the target app's named gap. The pure adapter
already exists (`MCP.Transport.StreamableHTTP.prepare/3` / `execute/3`).
Work: `%Plug.Conn{} → Request`, `Response → Conn`, SSE chunking off
`StreamResponse.subscription`, disconnect → cancellation, origin/header
admission reusing the existing policy. Sibling package (like the Tasks
packages) so the core keeps zero runtime deps. Test with the official Node
client (`interop/official_client/`), which already exercises HTTP.

## 3. `MCP.Client` transports (stdio, http) — S/M, after 1

`connect({:stdio, cmd, args})` over the existing framing;
`connect({:http, url})` as a plain POST client against 2 once it exists.

## 4. Ergonomics layer proper — M, after 1 (for demo value)

Extend the proven `MCP.Tool.Simple` precedent: `MCP.Resource.Simple`,
`MCP.Prompt.Simple`, inline `tool "name" do ... end` / `resource ... do`
blocks in `MCP.Server` (macro defines the module underneath — identical
registration), bare-term result normalization for resources/prompts (a
binary is text, a map is JSON, `{:error, msg}` is `isError`). Hard
non-goals from the assessment: no core edits (`MCP.Router`,
`MCP.Server.dispatch/3`, dialects untouched); low level stays the public
contract; mixing inline and module components must work; no atom→string
key conversion; `test/compliance/` never adopts any of this.

## 5. JSON Schema 2020-12 backend — M, independent

Sibling package behind the existing `MCP.Schema.Validator` boundary (24
LOC), wrapping an existing engine, external `$ref` fetching off by default.
Demanded by spike-findings, the readiness plan, and the compliance table's
"full wire-schema validation: not yet measured".

## 6. Conformance + interop in CI — S

Non-blocking job running the fixture server + `check.mjs` on push;
`workflow_dispatch` job for the frozen conformance runner uploading its
summary. ALSO: rerun conformance for a current score — the 22/37 figure is
an August observation and the September MRTR work did not rerun it (codex).

## 7. README protocol stance — XS

One paragraph: "`mcp_ex` speaks MCP `2026-07-28` only; use a client that
negotiates it." Honest, cheap, and closes the version question until item 8
triggers.

## 8. Legacy session-era dialect — L, DEFERRED

Trigger: a named deployment target rejects `2026-07-28`. Then: sibling
package `:mcp_ex_legacy` with its own conformance lane. Precondition
(codex): the session seam is UNPROVEN — `FutureDialect` is stateless,
`allow_session_id?` has no consumers, HTTP admission is POST-only — so the
first unit is a spike proving a session dialect fits the seam, not the
dialect itself. Assessment's mechanism list (§3) is the spike's checklist.

## Not doing (from the assessment, both models agree)

- No low-level rewrite for friendliness — everything above is additive.
- No Tasks-package widening until a workflow needs it.
- No progress/auth examples ahead of supported surfaces.
- No legacy dialect ahead of its trigger.
