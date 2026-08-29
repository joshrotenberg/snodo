# Conformance workspace

The executable internal wire contract lives under `test/compliance` and runs
with `mix mcp.contract`. Its report keeps four buckets separate:

- `internalPass`;
- `unsupported`;
- `unmeasured`;
- `officialPass`.

The native Streamable HTTP fixture is in [`fixture_server.exs`](fixture_server.exs).
The frozen official server run has now been measured. Its honest exercised
whole-scenario score is **22/37**; the raw runner had 25/37 scenarios without a
failure check, but three warning-only or missing-fixture paths are explicitly
excluded from the score. See the checked-in
[`human-readable summary`](results/2026-07-28-alpha.11-summary.md) and
[`machine-readable summary`](results/2026-07-28-alpha.11-summary.json).

There is no expected-failures baseline yet. Failures remain visible rather than
being converted into a passing CI result.

The frozen manifest is vendored at
[`requirements/2026-07-28.yaml`](requirements/2026-07-28.yaml) from conformance
commit `c321dd32035556e6769d3724a8ee97d87c3faaac`. `mix mcp.contract` verifies
its SHA-256
`ae2f4f6210fd729e2e318edd5bbfa31a43cee0bc608e48052fa26dbf1d939b57`
and exact 37-scenario server inventory before it reports evidence.

Start the combined fixture from the Tasks child package so both applications
are on the code path, then run the same frozen revision requirements from the
repository root:

```sh
cd extensions/tasks
MCP_PORT=3001 mix run ../../conformance/fixture_server.exs
```

```sh
npx -y @modelcontextprotocol/conformance@0.2.0-alpha.11 server \
  --url http://127.0.0.1:3001/mcp \
  --requirements 2026-07-28 \
  --output-dir conformance-results
```

The scored run attempted all 37 required scenarios and reported 89 success,
15 failure, 5 skipped, 2 warning, and 1 info checks. Two not-scored pending
scenarios also passed completely: `json-schema-2020-12` (8/8) and
`http-header-validation` (14/14). The remaining custom-header pending failure
stays visible in the checked-in summary.

See [the compliance architecture](../docs/protocol-compliance.md) for the
evidence boundary and rollout.

## Tasks extension visibility run

The same fixture now includes the released `io.modelcontextprotocol/tasks`
extension tools. The ten frozen alpha.11 Tasks scenarios are extension-only and
are intentionally kept separate from the 37 required core scenarios above.

All 35 Tasks-specific assertions pass. The upstream notification check is
skipped, and eight generic wire-schema checks reject the extension-defined flat
`CreateTaskResult` as a core `CallToolResult`; the runner therefore remains
non-zero. See the checked-in
[Tasks summary](results/2026-07-28-tasks-alpha.11-summary.md) and
[JSON companion](results/2026-07-28-tasks-alpha.11-summary.json).

Run one frozen Tasks scenario explicitly:

```sh
npx -y @modelcontextprotocol/conformance@0.2.0-alpha.11 server \
  --url http://127.0.0.1:3001/mcp \
  --scenario tasks-lifecycle \
  --spec-version 2026-07-28 \
  --force
```
