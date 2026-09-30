# AGENTS.md

Working instructions for coding agents, and a quick reference for people. [CONTRIBUTING.md](CONTRIBUTING.md) covers the same workflow in prose. Directories with their own tooling have their own `AGENTS.md`: [conformance/](conformance/AGENTS.md), [interop/](interop/AGENTS.md), and [extensions/tasks_postgres/](extensions/tasks_postgres/AGENTS.md). The closest file applies.

## Project

snodo is an Elixir library for Model Context Protocol (MCP) servers and clients. Eight Hex packages are built from this repository and released together at one version:

| Package | Directory | Contents |
|---|---|---|
| `snodo` | `.` | Router, server DSL, protocol dialects, client, stdio and HTTP transports, executor |
| `snodo_plug` | `integrations/plug` | Plug transport |
| `snodo_jsv` | `integrations/schema_jsv` | JSON Schema validator backed by JSV |
| `snodo_oauth` | `integrations/oauth` | OAuth 2.1 resource server plugs, JWT verification, scope policy, and the client authorization flows (`Snodo.OAuth.Client`) |
| `snodo_telemetry` | `integrations/telemetry` | Instrumentation sink that emits `:telemetry` events |
| `snodo_tasks` | `extensions/tasks` | Tasks extension, store contract, memory and DETS stores |
| `snodo_tasks_postgres` | `extensions/tasks_postgres` | PostgreSQL task store |
| `snodo_tasks_sqlite` | `extensions/tasks_sqlite` | SQLite task store |

Other directories:

| Path | Contents |
|---|---|
| `lib/snodo/protocol/` | `V2026_07_28` (default) and the opt-in initialize-era dialects `V2025_11_25` and `V2025_06_18` |
| `test/compliance/` | Literal protocol vectors |
| `conformance/` | The official conformance runner, pinned, with reviewed per-check baselines |
| `interop/` | Checks against the pinned official TypeScript client, and AJV validation of emitted messages |
| `examples/` | Numbered runnable scripts, each checked by `mix examples` |
| `guides/` | User documentation, published as ExDoc extras |
| `docs/history/` | Dated design records |

Inside the repository each sibling depends on `snodo` by path. `RELEASING.md` explains how they are published.

## Setup

Requirements: Elixir 1.18 or later on OTP 27 or later (CI runs 1.18/OTP 27, 1.19/OTP 28, and 1.20/OTP 29), and Node.js 24 for the interop and conformance checks. PostgreSQL is needed only for the live PostgreSQL lane.

```sh
mix setup                                      # dependencies for the core, the seven siblings, and the conformance fixture
(cd interop/official_client && npm ci --ignore-scripts)
```

Run `mix setup` again after pulling a change to any `mix.lock`. Install Node packages with `npm ci --ignore-scripts`, never `npm install`.

## Gates

Run all of these before every push. CI runs the same commands.

```sh
mix quality                                    # format, compile with warnings as errors, credo --strict, tests, contract, examples, every sibling
MIX_ENV=test mix quality.types                 # Dialyzer across all eight packages
MIX_ENV=dev mix docs --warnings-as-errors      # documentation build
mix compile && (cd interop/official_client && npm run check)   # official TypeScript client: baseline, MRTR, progress
```

- `mix quality` includes `mix snodo.contract`, which reports 32 evidence groups. A change that moves that count needs a reason in the pull request.
- A change to a transport or to what goes on the wire also runs the conformance lanes ([conformance/AGENTS.md](conformance/AGENTS.md)) and the wire-schema check ([interop/AGENTS.md](interop/AGENTS.md)).
- CI formats with Elixir 1.18 as well, and its formatter wraps some long lines differently. For each changed core file, with Docker available: `docker run --rm -i -w /tmp elixir:1.18-otp-27 mix format - < FILE | diff FILE -` should print nothing. Sibling files that import Ecto formatter settings can report false differences this way.

Narrower runs while working:

```sh
mix test test/router_acceptance_test.exs       # one file
mix test test/router_acceptance_test.exs:42    # the test at line 42
cd integrations/plug && mix test               # one sibling
mix run examples/01_direct_tools.exs --check   # one example in check mode
mix test --repeat-until-failure 100 --max-failures 1   # look for flaky tests; also try ERL_FLAGS="+S 2:2"
```

## Hard constraints

- The core has no Hex runtime dependencies. OTP applications are fine. A feature that needs a dependency goes in a sibling package.
- Wire names never change with the library name: `MCP-Protocol-Version`, `Mcp-Method`, `io.modelcontextprotocol/*`, and the PostgreSQL table `mcp_tasks`.
- Handler arguments and results use protocol-native string keys. There is no implicit conversion to atom keys.
- Convenience layers (`Simple` modules, inline components, the client) compile down to the low-level modules. Do not change `Snodo.Router`, `dispatch/3`, or the dialects to make a convenience layer work.
- Extension points are behaviours (`Snodo.Authorization`, `Snodo.Subscription.Source`, `Snodo.Extensions.Tasks.Store`, `Snodo.Instrumentation`, `Snodo.Schema.Validator`). Backends for specific external systems belong to applications or sibling packages, not the core.
- `test/compliance/` holds literal protocol messages. Never build requests there with `Snodo.Client` or `Snodo.Test`.
- Every limit has a default, is documented (`guides/transports.md` or the package README), and fails with a defined error.
- Conformance baselines are reviewed by hand. A newly passing check fails the gate too, until the baseline is updated on purpose ([conformance/AGENTS.md](conformance/AGENTS.md)).
- release-please owns the versions in the eight `mix.exs` files, `CHANGELOG.md`, and the install snippets between `x-release-please-start-version` and `x-release-please-end` markers. Do not edit them by hand.
- Records in `docs/history/` stay as written. Add a new dated record rather than editing an old one.

## Code style

- `mix format`. The formatter adds parentheses to DSL calls such as `argument(...)` and `tool(...)`.
- No compiler warnings, `credo --strict` clean, Dialyzer clean.
- Public modules and functions carry `@moduledoc` and `@doc`; internal ones use `@moduledoc false` or `@doc false`.
- Match the surrounding code's naming and comment density. Comments explain why, not what.
- Tests run `async: true` unless they share global state. When a test waits for another process, give `assert_receive` an explicit timeout; the 100 ms default fails under load (#111). Do not use `Process.sleep` to wait for something to happen.
- Prose in guides, docs, commit messages, and pull requests is plain and factual: say what changed and why, with no marketing language and no em dashes.

## Picking up work

- Every issue has a priority, a size, and usually an area:
  - `p1` blocking, `p2` standard queue, `p3` nice to have;
  - `size/small` 1 to 3 changed files, `size/medium` 4 to 10, `size/large` more than 10;
  - `area/protocol`, `area/client`, `area/transport`, `area/extensions`, `area/ci`, `area/docs`.
- `good first issue` marks small, well-scoped starting points.
- An issue body states the gap and a proposal. If the code and the proposal disagree, or the scope is unclear, say so on the issue before building.
- Check `gh pr list` and the issue's linked pull requests first, so work is not duplicated.

## Pull requests

1. Branch from `main`, named for the change type: `feat/...`, `fix/...`, `docs/...`, `test/...`, `ci/...`.
2. Open a draft pull request early, with the plan in the body.
3. Use conventional-commit titles for commits and the pull request: `feat:`, `fix:`, `docs:`, `test:`, `ci:`, `perf:`, `refactor:`, `chore:`. Mark a breaking change with `!` in the title and a `BREAKING CHANGE:` footer in a commit body. Pull requests are squash-merged, the squash message is built from the commit messages, and release-please builds the changelog from it.
4. Close issues with one keyword per issue: `Closes #12. Closes #13.` A comma list closes only the first.
5. The body says what changed and why, which tests cover it, the gate results, and anything left unaddressed.
6. Run the gates before every push. Mark the pull request ready when CI is green.

## Security

Report vulnerabilities privately as described in [SECURITY.md](SECURITY.md), not in issues or pull requests.
