# Conformance workspace

The internal wire contract runs with `mix snodo.contract`. Its implementation,
unsupported, unmeasured, and official evidence buckets stay separate.

The official runner has two legs. The server leg runs its scenarios against
the combined fixture. The [client leg](#client-leg) runs `Snodo.Client` against
the runner's own scenario servers. Each leg has its own score and baseline.

## Latest external measurement

The frozen alpha.11 runner passes **32/37 exercised whole required scenarios**
on 2026-09-14, up from the August 25 measurement of 22/37. Nine newly exercised
ordinary MRTR scenarios and ordinary progress now pass. All 37 required scenarios and 13 unscored
extension/pending scenarios were attempted.

Required checks: **103 success, 8 failure, 5 skipped, 0 warning, 1 info**.
The five remaining required scenarios concern deprecated sampling/roots, mixed
inputs requiring those features and incomplete diagnostic
fixtures. Internal and official-client elicitation capability tests do not
substitute for the frozen runner's sampling-specific diagnostics.

- [Current human-readable report](results/2026-09-14-alpha.11-summary.md)
- [Current machine-readable report](results/2026-09-14-alpha.11-summary.json)
- [Retained per-check outcomes](results/2026-09-14-alpha.11-checks.json)
- [Historical August 25 report](results/2026-07-28-alpha.11-summary.md)

## Reproducible regression lane

From the repository root:

```sh
mix deps.get
mix compile --warnings-as-errors
cd extensions/tasks
mix deps.get
mix compile --warnings-as-errors
cd ../../conformance
npm ci --ignore-scripts
npm test
npm run check
npm run check:client
```

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
The workflow being checked in does not mean its remote job has already passed.

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
cd extensions/tasks
MCP_PORT=3001 mix run ../../conformance/fixture_server.exs
```

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

The pending JSON Schema and standard HTTP-header probes pass 8/8 and 14/14,
respectively. Five pending custom-header checks remain unexercised failures.
These results do not establish general complete schema validation.

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
- `request-metadata` is excluded from the score: the client does not send
  `io.modelcontextprotocol/clientInfo` (a warning), and the deprecated roots and
  sampling capability checks are skipped because the client does not declare
  them.
- `http-standard-headers` is excluded from the score: its `initialize` and
  `notifications/initialized` checks are skipped because a 2026-07-28 client
  sends neither method. Every method the client does send carries the correct
  `Mcp-Method` and `Mcp-Name` headers.

See [protocol-compliance.md](../guides/protocol-compliance.md) for architecture and
[MRTR documentation](../guides/interactive-operations.md) for semantics and remaining limits.
