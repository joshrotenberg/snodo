# AGENTS.md: conformance

The official MCP conformance runner, pinned in `package-lock.json`, run as lanes against a fixture server built from the repository. [README.md](README.md) has the full description, the current scores, and the manual runner. The root [AGENTS.md](../AGENTS.md) applies here too.

## Run

From the repository root:

```sh
mix compile --warnings-as-errors
(cd conformance/fixture && mix deps.get && mix compile --warnings-as-errors)
cd conformance
npm ci --ignore-scripts
npm test                  # tests for the runner scripts themselves
npm run check             # 2026-07-28 server, native listener
npm run check:plug        # 2026-07-28 server, snodo_plug on Bandit
npm run check:2025-11-25  # initialize-era server lane
npm run check:2025-06-18  # initialize-era server lane
npm run check:client      # Snodo.Client against the runner's scenario servers
```

`conformance/fixture` is an unpublished Mix project that puts the core, `snodo_tasks`, `snodo_plug`, and Bandit on one code path for `fixture_server.exs`.

## Baselines

- `expected-failures.json` (also used by the Plug lane), `expected-failures-2025-11-25.json`, `expected-failures-2025-06-18.json`, and `expected-failures-client.json` are reviewed regression baselines, keyed by `scenario:check-id`. They are not waivers.
- A lane fails on a new failure, and also on a stale expected failure, a newly passing check, or any changed check status. When a change makes a check pass, update the baseline in the same pull request and say which check changed and why.
- The runner never writes the baselines or the `checkInventory`. Edit them by hand from the raw results the lane writes under `tmp/conformance/`.
- A green lane means "matches the reviewed baseline", not full conformance. Do not describe it as full conformance in docs or pull requests.
- Updating the pinned runner version is its own reviewed change, with the baseline and inventory updates it requires.
