# Static analysis gates

## Status

Credo and Dialyxir are implemented as development/test-only quality gates for
all four Mix packages. They do not change any runtime dependency graph:

- [Credo 1.7.19](https://hex.pm/packages/credo/1.7.19) runs in strict mode over
  core `lib`, `test`, `examples`, and `conformance`, and over all three
  extension packages' `lib` and `test` trees;
- [Dialyxir 1.4.7](https://hex.pm/packages/dialyxir/1.4.7) runs in the development
  environment with `:unmatched_returns` and `:error_handling` enabled;
- all four packages declare those tools with
  `only: [:dev, :test], runtime: false`;
- standalone core `mcp_ex` has no runtime dependency, while child
  `:mcp_ex_tasks` has a one-way runtime dependency only on `mcp_ex`;
- optional `:mcp_ex_tasks_postgres` depends one way on Tasks plus Ecto SQL and
  Jason; Postgrex remains optional because the host application supplies and
  supervises its PostgreSQL-backed `Ecto.Repo`;
- optional `:mcp_ex_tasks_sqlite` also depends one way on Tasks plus Ecto SQL
  and Jason; `ecto_sqlite3` remains optional because the host application
  supplies and supervises its SQLite-backed Repo;
- the current tree passes both gates without a Dialyzer ignore file; Credo's
  narrow naming and alias policies are documented beside their configuration.

The initial analysis was used as design feedback rather than baselined away.
It led to tighter return contracts, explicit executor outcome types, simpler
profile validation, checked Logger configuration changes, and removal of
unreachable or unmatched branches.

The recorded local verification environment is Elixir 1.20.3 on OTP 29. All
four projects declare Elixir `~> 1.18`; the checked-in compatibility workflow
now defines 1.18/OTP 27, 1.19/OTP 28, and 1.20/OTP 29 lanes. Combinations other
than the local environment become evidence only after their jobs pass. The core suite currently has 154 tests
and 25 contract groups; the Tasks package has 80 tests and 10 local contract
groups. The PostgreSQL package has 9 database-independent tests and 1 local
contract group, plus 14 real-database tests across 7 live evidence groups. The
SQLite package has 19 file-backed integration tests across 7 local evidence
groups.

## Commands

The fast local gate is:

```sh
mix quality
```

It runs, in order:

```sh
mix format --check-formatted
mix compile --warnings-as-errors
mix credo --strict
mix test --warnings-as-errors
mix examples
mix cmd --cd extensions/tasks mix quality
mix cmd --cd extensions/tasks_postgres mix quality
mix cmd --cd extensions/tasks_sqlite mix quality
```

`mix examples` launches every numbered script in a fresh Mix/Elixir VM, starts
runtime dependencies normally, promotes script compiler warnings to errors, and
requires its exact one-line success marker. The root task runs examples 01–06
and the Resources/Prompts/Completion/Pagination/Subscriptions examples 12–16
plus the bounded producer and instrumentation examples 18–19 in the core,
delegates examples 07–09 and 17 to `:mcp_ex_tasks`, and delegates embedded example 11 to
`:mcp_ex_tasks_sqlite`, for eighteen no-external-service walkthroughs. The
present suite requires a POSIX host with `sh` and `mkfifo` for the real stdio
subprocess half-close check.

The child packages can also be checked directly:

```sh
cd extensions/tasks
mix quality
mix quality.types
mix tasks.contract
mix examples
mix tasks.stress

cd ../tasks_postgres
mix quality
mix quality.types
mix tasks.postgres.contract

cd ../tasks_sqlite
mix quality
mix quality.types
mix tasks.sqlite.contract
mix example.sqlite
```

`mix tasks.stress` is an opt-in deterministic workload, not part of the fast
`mix quality` alias. It emits exact correctness invariants and descriptive
timings; larger scheduled runs can retain its versioned JSON form as an
artifact.

The PostgreSQL transaction lane is deliberately opt-in and requires a
dedicated database URL:

```sh
cd extensions/tasks_postgres
MCP_TASKS_DATABASE_URL=ecto://postgres:postgres@127.0.0.1:55432/mcp_ex_tasks \
  mix quality.postgres
```

The slower type gate stays separate so it can run in parallel locally or in CI:

```sh
mix quality.types
```

That root alias runs Dialyzer in short format, checks for stale filters, and
then delegates the same gate to all three extension packages:

```sh
mix dialyzer --format short --list-unused-filters
mix cmd --cd extensions/tasks mix quality.types
mix cmd --cd extensions/tasks_postgres mix quality.types
mix cmd --cd extensions/tasks_sqlite mix quality.types
```

Protocol evidence remains a separate lane:

```sh
mix mcp.contract
```

The core task covers its 15 groups. Tasks contract evidence remains local to
the one-way-dependent child and runs with `mix tasks.contract` from
`extensions/tasks`. The PostgreSQL package similarly owns its database-free
adapter group and 7 live transaction groups. The core compliance inventory
does not absorb extension persistence evidence. SQLite owns 7 local,
file-backed transaction groups through `mix tasks.sqlite.contract`.

This separation is intentional. Style/type cleanliness and protocol-conformance
evidence answer different questions and neither substitutes for the other.

## Configuration choices

Credo uses its normal strict check set with narrow, documented conventions:

- private compiled test fixtures under `MCPEx.*` are not required to publish
  module documentation;
- exact-revision modules such as `V2026_07_28` retain the wire version in their
  module name;
- fully qualified names remain visible at protocol, DSL-quote, and private
  fixture boundaries unless both nesting and repetition make an alias clearer.

All findings outside those explicit policies were fixed. Core examples remain
in the root developer-experience inputs. Each child has its own formatter and
Credo inputs. The Tasks example alias executes examples 07–09 and 17 against that
dependency graph; the PostgreSQL setup walkthrough stays in the opt-in live
database lane; the SQLite sibling owns the embedded example 11 check; and core
examples 12–16 and 18–19 exercise Resources list/template/read, Prompts list/get,
contextual Completion callbacks, shared list pagination, and the application
subscription-source lifecycle, including cache overrides, routing failures,
required arguments, and bounded event delivery without an external service.

Dialyzer uses a project-local PLT directory:

```elixir
dialyzer: [
  plt_add_apps: [:mix],
  plt_local_path: "priv/plts",
  flags: [:unmatched_returns, :error_handling]
]
```

`:mix` is present because the packages ship contract, example, and live
database Mix tasks. Each project owns its PLT. PLTs and their hashes are
generated, machine-specific artifacts and are ignored. The
`:underspecs` warning class remains advisory while the public API is still being
spiked; it is not part of the merge gate.

## CI shape

When this spike moves into a repository, wire four independent jobs:

1. root `mix quality` for core format, compilation, Credo, 108 ExUnit tests, the
   eleven default isolated examples, and delegated no-external-service child quality;
2. root `mix quality.types` for all four Dialyzer gates with separately cached
   PLTs;
3. `mix mcp.contract` for 15 machine-readable core evidence groups and child
   `mix tasks.contract` for its 8 local groups, plus
   `mix tasks.sqlite.contract` for 7 embedded-database groups; and
4. PostgreSQL-backed `mix quality.postgres` for 13 integration tests across 7
   live evidence groups, with the service version recorded in CI.

Each PLT cache key should include the project path, operating system, OTP
version, Elixir version, Mix environment, corresponding `mix.exs`, and
corresponding `mix.lock`. CI wiring is not included in this spike, so the
aliases are active locally but are not yet protected branch checks.

## Suppression policy

- Credo exclusions require a short rationale beside the configuration.
- Dialyzer filters, if ever needed, must be narrow term-format entries linked to
  a concrete analyzer limitation or tracked issue.
- `--list-unused-filters` remains mandatory so obsolete filters fail the gate.
- A whole module or warning class is never ignored merely to obtain a green
  build.
- Tool and runtime upgrades should re-run the gates from a clean PLT.
