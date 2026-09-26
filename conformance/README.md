# Conformance workspace

The internal wire contract runs with `mix snodo.contract`. Its implementation,
unsupported, unmeasured, and official evidence buckets stay separate.

The official runner has two legs. The server leg runs its scenarios against
the combined fixture. The [client leg](#client-leg) runs `Snodo.Client` against
the runner's own scenario servers. `run.mjs` runs them as lanes, each with its
own score and baseline: `server`, `client`, and the
[additional server lanes](#additional-server-lanes) `server-plug`,
`server-2025-11-25`, and `server-2025-06-18`.

## Latest external measurement

The frozen alpha.11 runner passes **32/37 exercised whole required scenarios**
on 2026-09-26, the same score as the 2026-09-14 run and up from the August 25
measurement of 22/37. All 37 required scenarios and 13 unscored
extension/pending scenarios were attempted.

Required checks: **110 success, 6 failure, 0 skipped, 0 warning, 1 info**.
Since 2026-09-14, the fixture has a subscription hub and the diagnostic tools
`server-stateless` calls: `test_trigger_tool_change`, `test_trigger_prompt_change`,
`test_streaming_elicitation`, and `test_logging_tool`. Five subscription checks
that were skipped and two diagnostics that failed now pass. `test_logging_tool`
passes because Snodo never sends the deprecated `notifications/message`.

The five remaining required scenarios all depend on the deprecated sampling
and roots features, which Snodo does not implement. Internal and
official-client elicitation capability tests do not substitute for the frozen
runner's sampling-specific diagnostics.

- [Current human-readable report](results/2026-09-26-alpha.11-summary.md)
- [Current machine-readable report](results/2026-09-26-alpha.11-summary.json)
- [Retained per-check outcomes](results/2026-09-26-alpha.11-checks.json)
- [Historical September 14 report](results/2026-09-14-alpha.11-summary.md)
- [Historical August 25 report](results/2026-07-28-alpha.11-summary.md)

## Reproducible regression lane

From the repository root:

```sh
mix deps.get
mix compile --warnings-as-errors
cd conformance/fixture
mix deps.get
mix compile --warnings-as-errors
cd ..
npm ci --ignore-scripts
npm test
npm run check
npm run check:client
npm run check:plug
npm run check:2025-11-25
npm run check:2025-06-18
```

`conformance/fixture` is a small Mix project, never published, that puts the
core, `snodo_tasks`, `snodo_plug`, and Bandit on one code path for
`fixture_server.exs`.

The launcher uses the dev build and starts the combined fixture on an
OS-assigned loopback port. Startup, runner execution, and shutdown are bounded;
stdin EOF shuts down the fixture. No public application services are contacted.
Each invocation creates a fresh directory under `tmp/conformance/server/` or
`tmp/conformance/client/` (override with `MCP_CONFORMANCE_OUTPUT`), keeping
stale files out of the score.

The frozen manifest is vendored at
[requirements/2026-07-28.yaml](requirements/2026-07-28.yaml), from commit
`c321dd32035556e6769d3724a8ee97d87c3faaac`. Both the internal contract and managed
runner verify SHA-256
`ae2f4f6210fd729e2e318edd5bbfa31a43cee0bc608e48052fa26dbf1d939b57`.
The managed runner additionally verifies the installed manifest is byte-identical.
The npm lockfile pins alpha.11 and its transitive dependencies; use `npm ci`,
not a moving `npx` dependency resolution, for comparable runs.

[Protocol CI](../.github/workflows/protocol.yml) runs this lane and uploads raw
checks, runner/fixture logs, and the summary even when the regression check fails.
Each run also appends its Markdown summary to the job's step summary.
The workflow being checked in does not mean its remote job has already passed.

## Canary and dependency updates

The [conformance canary](../.github/workflows/canary.yml) runs weekly and on
demand. It runs both legs against the runner's `alpha` dist-tag and against a
build of upstream `main`, with `MCP_CONFORMANCE_RUNNER` pointing `run.mjs` at
that build. In that mode the pinned version and installed-manifest checks are
skipped. The runner's own frozen manifest is used, so scenarios added after the
pin appear as baseline differences. The job never fails the workflow. Its step
summary notes whether the `alpha` tag has moved past the pin and shows every
difference from the reviewed baselines, and its artifacts keep the raw checks.

[Dependabot](../.github/dependabot.yml) proposes weekly updates for the npm
lockfiles in `conformance/`, `interop/official_client/`, and
`interop/schema_validation/`, and for the GitHub Actions in use. A runner or
official client bump fails its pinned lane until the pin, the baseline, and the
check inventory are updated in a reviewed change.

## Honest baseline policy

[expected-failures.json](expected-failures.json) is a reviewed,
`scenario:check-id` regression baseline, not a conformance waiver. It covers
required and unscored failures separately by their exact keys. Where alpha.11
repeats a check ID for parameterized cases, the report preserves each occurrence
with a numbered suffix.

Its human-readable `checkInventory` also pins every check ID and its ordered
status occurrences across all 50 required and unscored scenarios. Repeated IDs
retain every occurrence rather than collapsing to one status. This inventory is
checked in from reviewed raw evidence; the runner never updates it automatically.

The gate fails on new failures, stale expected failures, missing/extra scenario
artifacts, empty or malformed checks, new/stale excluded required scenarios,
and every missing, new, or changed check/status occurrence. This includes a
success becoming skipped or warning inside an already-failing or unscored
scenario. Even newly passing checks require a deliberate baseline review.
A failure-free scenario counts only when it has semantic successes and no
warnings or skipped checks; a schema-only success cannot stand in for a fixture.

The official runner still exits **1** for this partial implementation. The managed
lane can exit **0** only when those same failures match the reviewed baseline;
the report retains the runner exit code, failures, and **32/37** score. Never
call a passing regression gate full protocol conformance.

## Manual runner

To investigate a single case:

```sh
cd conformance/fixture
MCP_PORT=3001 mix run ../fixture_server.exs
```

Set `MCP_FIXTURE_TRANSPORT=plug` to serve it through `Snodo.Transport.Plug` on
Bandit, and `MCP_FIXTURE_PROFILE=legacy` for the initialize-era runtime.

In another terminal, from `conformance`:

```sh
node node_modules/@modelcontextprotocol/conformance/dist/index.js server \
  --url http://127.0.0.1:3001/mcp \
  --scenario input-required-result-basic-elicitation \
  --spec-version 2026-07-28 --force
```

The managed lane runs `--requirements 2026-07-28`, never a moving `--suite all`.

## Tasks and pending scenarios

Tasks is extension-only: its scenarios do not increase the 37-scenario core score.
The fresh run retains all **35 Tasks-specific assertions passing**, the upstream
status-notification check skipped, and eight generic wire-schema failures.
Those failures validate the extension-defined flat `CreateTaskResult` against
the core `CallToolResult`, which requires `content`; they are not erased.

The pending JSON Schema, standard HTTP-header, and custom-header server
validation probes pass 8/8, 14/14, and 10/10 checks. The custom-header scenario
calls the fixture's `custom_header_region` tool, whose `region` argument carries
`x-mcp-header`. These results do not establish general complete schema
validation.

## Additional server lanes

- `server-plug` runs the same 2026-07-28 fixture through `Snodo.Transport.Plug`
  on Bandit instead of the native listener. On 2026-09-26 it matched the native
  lane check for check (32/37), so it shares `expected-failures.json`: any
  difference between the two listeners fails one of the gates.
- `server-2025-11-25` enables the initialize-era dialects next to 2026-07-28 on
  a fixture with tools, resources, prompts, and completion, and runs the frozen
  2025-11-25 requirement set. That set is the upstream reconstruction from
  alpha.10 (see the header of
  [requirements/2025-11-25.yaml](requirements/2025-11-25.yaml)), pinned by
  SHA-256. It passes **21/30** required scenarios. The failures are features
  the initialize-era slice does not implement: `logging/setLevel`,
  server-initiated sampling and elicitation (which need a session),
  `resources/subscribe`, and SSE session IDs. They are listed with reasons in
  [expected-failures-2025-11-25.json](expected-failures-2025-11-25.json).
- `server-2025-06-18` runs `--spec-version 2025-06-18 --suite active` on the
  same fixture. No frozen requirement set exists for 2025-06-18, so all 27
  scenarios are unscored; 21 pass, and the other 6 fail for the same missing
  features. The per-check baseline in
  [expected-failures-2025-06-18.json](expected-failures-2025-06-18.json) still
  gates every change.

Results: [Plug](results/2026-09-26-plug-alpha.11-summary.md),
[2025-11-25](results/2026-09-26-2025-11-25-alpha.11-summary.md),
[2025-06-18](results/2026-09-26-2025-06-18-alpha.11-summary.md).

## Client leg

`npm run check:client` runs `client --requirements 2026-07-28`: 32 required
scenarios and 7 unscored ones. For each scenario the runner starts a scenario
server and runs [client.exs](client.exs) with `mix run` from the repository
root, so the root project must be compiled in the dev environment. The harness
drives `Snodo.Client` the way an application would and adds no protocol
behavior: discover, list tools, call the tools the scenario context names (or
every listed tool with arguments sampled from its schema), answer
`input_required` results, and list and read resources and prompts when the
server advertises them. The runner scores the traffic its scenario server
records.

The 2026-09-26 run passes **6/32** whole required scenarios: `tools_call`,
`sep-2322-client-request-state`, `http-custom-headers`,
`http-invalid-tool-headers`, `json-schema-ref-no-deref`, and
`auth/resource-mismatch`. The last passes only because the harness never starts
authorization; it is not evidence of OAuth support. The unscored
`json-schema-2020-12-preservation` scenario passes. The first run that day,
before `Snodo.Client` sent `Mcp-Param-*` headers, passed 4/32.

- [Client report](results/2026-09-26-client-alpha.11-summary.md)
- [Client machine-readable report](results/2026-09-26-client-alpha.11-summary.json)
- [Client per-check outcomes](results/2026-09-26-client-alpha.11-checks.json)

[expected-failures-client.json](expected-failures-client.json) follows the
same policy as the server baseline, with every check of all 39 scenarios
pinned. The remaining gaps:

- The 25 required and 6 unscored `auth/*` scenarios: `Snodo.Client` has no
  OAuth support, and the harness exits before sending a request.
- `request-metadata` is excluded from the score: the deprecated roots and
  sampling capability checks are skipped because the client does not declare
  them. Its other checks pass, including `io.modelcontextprotocol/clientInfo`.
- `http-standard-headers` is excluded from the score: its `initialize` and
  `notifications/initialized` checks are skipped because a 2026-07-28 client
  sends neither method. Every method the client does send carries the correct
  `Mcp-Method` and `Mcp-Name` headers.

See [protocol-compliance.md](../guides/protocol-compliance.md) for architecture and
[MRTR documentation](../guides/interactive-operations.md) for semantics and remaining limits.
