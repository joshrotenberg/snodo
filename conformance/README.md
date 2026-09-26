# Conformance workspace

The internal wire contract runs with `mix snodo.contract`. Its implementation,
unsupported, unmeasured, and official evidence buckets stay separate.

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
cd extensions/tasks
mix deps.get
mix compile --warnings-as-errors
cd ../../conformance
npm ci --ignore-scripts
npm test
npm run check
```

The launcher uses the dev build and starts the combined fixture on an
OS-assigned loopback port. Startup, runner execution, and shutdown are bounded;
stdin EOF shuts down the fixture. No public application services are contacted.
Each invocation creates a fresh directory under `tmp/conformance/`
(override with `MCP_CONFORMANCE_OUTPUT`), keeping stale files out of the score.

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

See [protocol-compliance.md](../guides/protocol-compliance.md) for architecture and
[MRTR documentation](../guides/interactive-operations.md) for semantics and remaining limits.
