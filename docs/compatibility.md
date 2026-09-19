# Compatibility and migration evidence

The executable compatibility policy lives in
[`compatibility.yml`](../.github/workflows/compatibility.yml). It separates
language/runtime compatibility, database behavior, and migration behavior so a
pass in one lane cannot be presented as evidence for another.

The workflow is checked-in executable policy, not a retroactive pass claim.
This workspace has locally verified the current Elixir/OTP lane and SQLite
migration sequence. Each other combination becomes measured evidence only when
its CI job completes successfully.

## BEAM matrix

All six packages declare Elixir `~> 1.18`: core, Tasks, two Tasks databases,
Plug integration, and JSV validation integration. The matrix exercises these supported
pairs:

| Lane | Elixir | Erlang/OTP | Evidence |
|---|---:|---:|---|
| minimum | 1.18 | 27 | Aggregate formatting, warning-free compilation, strict Credo, tests, contracts, and examples |
| intermediate | 1.19 | 28 | Same aggregate quality gate |
| current | 1.20 | 29 | Aggregate quality plus Dialyzer for all packages |

These are intentional diagonal pairs, not a claim for every Cartesian
combination. Elixir's compatibility table supports 1.18 on OTP 25–27, 1.19 on
OTP 26–28, and 1.20 on OTP 27–29; this project currently chooses OTP 27 as its
minimum operational target. Expanding the OTP floor requires a separate lane
rather than inference from the Elixir version requirement. The pairings follow
Elixir's official [compatibility table](https://hexdocs.pm/elixir/main/compatibility-and-deprecations.html),
and the workflow uses the Erlang Ecosystem Foundation's
[`setup-beam`](https://github.com/erlef/setup-beam) action.

## Independent protocol and client lanes

The current BEAM lane also runs the lockfile-pinned official TypeScript client
2.0.0 baseline, MRTR, and progress checks over stdio and native HTTP. Progress
wire correctness and the SDK's callback scheduling limitation are recorded
[separately](../interop/official_client/PROGRESS.md).

[`protocol.yml`](../.github/workflows/protocol.yml) adds two independent jobs:
the exact frozen alpha.11 conformance runner with a strict per-check regression
baseline, and AJV validation of representative real emitted messages against a
digest-pinned official schema. Both upload their local evidence as artifacts.
A baseline pass is not full conformance, and a corpus pass is not a proof of all
possible protocol output. No remote CI execution is inferred from local results.

## PostgreSQL matrix

The live PostgreSQL contract runs independently on major versions 14, 16, and
18 using ordinary pooled Repo connections. Each lane exercises real row locks,
`FOR UPDATE SKIP LOCKED`, database-clock lease decisions, rollback, hard-Runner
recovery, the example application, and the v1-to-v2 migration fixture.

The selected versions cover the oldest supported project target, an
intermediate release, and the current stable major as of this matrix. The
workflow uses floating major container tags so it receives current PostgreSQL
minor security and bug-fix releases. Artifact provenance should record the
exact server version returned by a run when release evidence is retained.
The selected supported-major policy follows PostgreSQL's official
[five-year versioning policy](https://www.postgresql.org/support/versioning/).

SQLite remains an embedded, dependency-selected engine rather than a service
matrix. Its default contract runs against the actual `sqlite_version()` linked
by `exqlite` and real temporary WAL files on every BEAM lane. That is evidence
for the resolved engine, not for arbitrary system SQLite releases.

## Schema versions

Both Ecto adapters now expose the same explicit chain:

| Module | Version | Purpose |
|---|---:|---|
| `Migration.V1` | 1 | Immutable historical aggregate and event-ledger schema |
| `Migration.V2` | 2 | Data-preserving event commit-time lookup index and metadata bump |
| `Migration` | 2 | Fresh install composed through all current steps; destructive full rollback |

Applications upgrading an existing installation should wrap `Migration.V2` in
their own next Ecto migration. Fresh applications wrap `Migration`. The
adapters never invoke either module automatically.

The SQLite contract executes a real sequence with seeded Task and event data:

```text
empty -> V1 -> seed -> V2 -> verify -> down V2 -> verify V1 data -> V2 -> verify
```

The PostgreSQL live contract performs the same sequence in an isolated schema
for each database-matrix lane. At version one, `check_schema/1` fails closed
with `{:unsupported_schema_version, 1}` while Store operations remain available
to the application-controlled migration fixture. At version two, the adapter
accepts the schema and the original snapshot and event history must be exactly
unchanged.

`Migration.V2.down/0` or `down/1` is data-preserving. The current facade's
`Migration.down/0` or `down/1` intentionally drops the complete Tasks schema and
all data, matching its fresh-install ownership boundary.

## Local commands

The locally available lanes are:

```sh
mix quality
mix quality.types

cd extensions/tasks_sqlite
mix tasks.sqlite.contract

cd ../tasks_postgres
MCP_TASKS_DATABASE_URL=ecto://postgres:postgres@127.0.0.1:55432/mcp_ex_tasks \
  mix quality.postgres
```

Running a different Elixir/OTP or PostgreSQL version locally is useful, but it
does not update the declared matrix until the workflow itself carries that
lane.
