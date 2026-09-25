# Static analysis gates

## Status

Credo and Dialyxir are implemented as development/test-only quality gates for
all six Mix packages. They do not change any runtime dependency graph:

- [Credo 1.7.19](https://hex.pm/packages/credo/1.7.19) runs in strict mode over
  core `lib`, `test`, `examples`, and `conformance`, and over all three
  extension packages' and two integration packages' `lib` and `test` trees;
- [Dialyxir 1.4.7](https://hex.pm/packages/dialyxir/1.4.7) runs in the development
  environment with `:unmatched_returns` and `:error_handling` enabled;
- all six packages declare those tools with
  `only: [:dev, :test], runtime: false`;
- standalone core `snodo` has no runtime dependency, while child
  `:snodo_tasks` has a one-way runtime dependency only on `snodo`;
- optional `:snodo_tasks_postgres` depends one way on Tasks plus Ecto SQL and
  Jason; Postgrex remains optional because the host application supplies and
  supervises its PostgreSQL-backed `Ecto.Repo`;
- optional `:snodo_tasks_sqlite` also depends one way on Tasks plus Ecto SQL
  and Jason; `ecto_sqlite3` remains optional because the host application
  supplies and supervises its SQLite-backed Repo;
- optional `:snodo_plug` and `:snodo_jsv` depend inward on the core and add
  Plug hosting and JSV validation respectively; they are not protocol extensions;
- the current tree passes both gates without a Dialyzer ignore file; Credo's
  narrow naming and alias policies are documented beside their configuration.

The initial analysis was used as design feedback rather than baselined away.
It led to tighter return contracts, explicit executor outcome types, simpler
profile validation, checked Logger configuration changes, and removal of
unreachable or unmatched branches.

The current local verification environment is Elixir 1.20.4 on OTP 29.0.6. All
six projects declare Elixir `~> 1.18`; the checked-in compatibility workflow
now defines 1.18/OTP 27, 1.19/OTP 28, and 1.20/OTP 29 lanes. Combinations other
than the local environment become evidence only after their jobs pass. At the
initial package split, the core suite had 154 tests
and 25 contract groups; the Tasks package has 80 tests and 10 local contract
groups. The PostgreSQL package has 9 database-independent tests and 1 local
contract group, plus 14 real-database tests across 7 live evidence groups. The
SQLite package has 19 file-backed integration tests across 7 local evidence
groups. Current application reconciliation results are recorded in
[target application findings](target-application-findings.md); the runner's
output remains authoritative for current test counts.

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
mix test --warnings-as-errors --raise
mix snodo.contract
mix examples
mix cmd --cd extensions/tasks mix quality
mix cmd --cd extensions/tasks_postgres mix quality
mix cmd --cd extensions/tasks_sqlite mix quality
mix cmd --cd integrations/plug mix quality
mix cmd --cd integrations/schema_jsv mix quality
```

`mix examples` launches every numbered script in a fresh Mix/Elixir VM, starts
runtime dependencies normally, promotes script compiler warnings to errors, and
requires its exact one-line success marker. The root task runs examples 01–06
and the Resources/Prompts/Completion/Pagination/Subscriptions examples 12–16
plus the bounded producer, instrumentation, and MRTR examples 18–20 in the core,
delegates examples 07–09 and 17 to `:snodo_tasks`, and delegates embedded example 11 to
`:snodo_tasks_sqlite`. Examples 21/22 use the Plug and JSV integrations, for
twenty-one no-external-service walkthroughs. The
present suite requires a POSIX host with `sh` and `mkfifo` for the real stdio
subprocess half-close check.

Tasks, storage, and JSV example aliases use `mix snodo.example PATH` to preserve the active Mix
environment and build path in an isolated VM. This matters when `quality`
selects test through `preferred_envs` without an explicit `MIX_ENV` variable.
Quality test steps use `--raise` to stop the alias immediately on a failure;
compiler warnings and non-zero example exits also fail the gate.

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
SNODO_TASKS_DATABASE_URL=ecto://postgres:postgres@127.0.0.1:55432/snodo_tasks \
  mix quality.postgres
```

The slower type gate stays separate. Run it after quality locally to avoid
competing dependency builds, or in an independent CI checkout:

```sh
mix quality.types
```

That root alias runs Dialyzer in short format, checks for stale filters, and
then delegates the same gate to all three extension and two integration packages:

```sh
mix dialyzer --format short --list-unused-filters
mix cmd --cd extensions/tasks mix quality.types
mix cmd --cd extensions/tasks_postgres mix quality.types
mix cmd --cd extensions/tasks_sqlite mix quality.types
mix cmd --cd integrations/plug mix quality.types
mix cmd --cd integrations/schema_jsv mix quality.types
```

Protocol evidence remains a separate lane:

```sh
mix snodo.contract
```

The core task covers its 31 groups. Tasks contract evidence remains local to
the one-way-dependent child and runs with `mix tasks.contract` from
`extensions/tasks`. The PostgreSQL package similarly owns its database-free
adapter group and 7 live transaction groups. The core compliance inventory
does not absorb extension persistence evidence. SQLite owns 7 local,
file-backed transaction groups through `mix tasks.sqlite.contract`.

This separation is intentional. Style/type cleanliness and protocol-conformance
evidence answer different questions and neither substitutes for the other.

## Configuration choices

Credo uses its normal strict check set with narrow, documented conventions:

- private compiled test fixtures under `SnodoTest.*` are not required to publish
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

The private repository now contains compatibility and protocol workflows:

1. Root `mix quality` on minimum/intermediate/current BEAM combinations, with
   `mix quality.types` on the current lane. Quality includes core and extension
   contract inventories and all 21 default isolated examples.
2. A PostgreSQL 14/16/18 service matrix running the live adapter contract and
   walkthrough separately from database-independent quality.
3. Pinned official TypeScript client baseline/MRTR/progress acceptance.
4. Frozen external-runner regression and independent AJV emitted-wire validation,
   retaining their evidence artifacts and distinct conformance claims.

These workflow files have not been verified by a remote run in this slice, and
their presence does not establish branch protection. The BEAM workflow sets
`MIX_ENV=test`; the standalone local type alias defaults to dev when no explicit
environment is supplied. Record the actual environment with each result.

If PLT caching is introduced, each cache key should include project path,
operating system, OTP, Elixir, Mix environment, `mix.exs`, and `mix.lock`.

## Suppression policy

- Credo exclusions require a short rationale beside the configuration.
- Dialyzer filters, if ever needed, must be narrow term-format entries linked to
  a concrete analyzer limitation or tracked issue.
- `--list-unused-filters` remains mandatory so obsolete filters fail the gate.
- A whole module or warning class is never ignored merely to obtain a green
  build.
- Tool and runtime upgrades should re-run the gates from a clean PLT.
